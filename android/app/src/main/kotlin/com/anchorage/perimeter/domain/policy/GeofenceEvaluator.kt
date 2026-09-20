package com.anchorage.perimeter.domain.policy

import com.anchorage.perimeter.domain.geo.DistanceCalculator
import com.anchorage.perimeter.domain.model.LocationFix
import com.anchorage.perimeter.domain.model.OfficeAnchor

/**
 * Answers the one question the whole app is built around: **"is the user at
 * the office?"**
 *
 * It is a pure function in class form:
 *
 * ```
 * (office anchor, GPS fix, where they were last time) ──► GeofenceReading
 * ```
 *
 * No state, no I/O, no Android. Give it the same three inputs and it returns
 * the same answer every time, which is why it can be tested exhaustively on
 * the JVM in milliseconds.
 *
 * ## Who calls it
 *
 * Two places, for two different purposes:
 *
 * - [com.anchorage.perimeter.domain.usecase.ObserveAttendanceStatusUseCase] —
 *   every two seconds, to drive the dial. Passes `previousStatus`, so
 *   hysteresis applies and the display stays steady.
 * - [com.anchorage.perimeter.domain.usecase.MarkAttendanceUseCase] — once, at
 *   the moment of check-in. Passes **no** `previousStatus`, so the true 50 m
 *   fence is enforced with no forgiveness.
 *
 * That difference is the whole hysteresis design in one sentence: smooth the
 * *display*, never the *decision*.
 *
 * @param distanceCalculator How to measure between two coordinates. Injected
 *   as an interface so the policy can be tested against a stub returning
 *   exact, hand-chosen distances — which separates "is the arithmetic right?"
 *   from "is the rule right?".
 * @param policy The four tunable numbers. See [GeofencePolicy].
 */
class GeofenceEvaluator(
    private val distanceCalculator: DistanceCalculator,
    private val policy: GeofencePolicy = GeofencePolicy.Default,
) {

    /**
     * The fence this evaluator is enforcing, for the screen to *say*.
     *
     * Exposed so the copy under the dial ("move within 50 metres") reads the
     * same number the decision uses. The UI used to reach for
     * [GeofencePolicy.DEFAULT_RADIUS_METERS] directly, which was correct only
     * for as long as nothing ever supplied a different radius — and a
     * server-issued site radius is exactly the change that would have made
     * the screen quietly lie.
     */
    val radiusMeters: Double get() = policy.radiusMeters

    /**
     * Measures [fix] against [anchor] and decides which side of the fence the
     * user is on.
     *
     * @param anchor The saved office — the centre of the circle.
     * @param fix Where the phone currently believes it is.
     * @param previousStatus Where the user was judged to be on the *previous*
     *   reading, or `null` to judge this fix on its own merits.
     *
     *   Passing it in enables the hysteresis described below. Passing `null`
     *   enforces the strict fence. The caller decides which it wants; this
     *   class holds no state of its own, which keeps it trivially testable
     *   and safe to call from any thread.
     *
     * @return A [GeofenceReading] carrying the distance, the verdict, and
     *   whether the fix was accurate enough to believe.
     */
    fun evaluate(
        anchor: OfficeAnchor,
        fix: LocationFix,
        previousStatus: ProximityStatus? = null,
    ): GeofenceReading {
        // Step 1 — how far apart are the two coordinates?
        val distance = distanceCalculator.distanceMeters(anchor.point, fix.point)

        // Step 2 — pick the threshold to compare against.
        //
        // Schmitt trigger: the line you must cross depends on where you
        // already were. Entering requires <= 50 m; leaving requires > 58 m.
        // A user standing still on the boundary therefore stays put in
        // whichever state they were in, instead of flickering.
        val threshold = if (previousStatus == ProximityStatus.INSIDE) {
            policy.exitRadiusMeters
        } else {
            policy.radiusMeters
        }

        // Step 3 — the verdict.
        val status = if (distance <= threshold) ProximityStatus.INSIDE else ProximityStatus.OUTSIDE

        // Step 4 — package it up with everything the UI needs to explain
        // itself, including how much to trust the answer.
        return GeofenceReading(
            distanceMeters = distance,
            // Always the *true* radius, never the widened exit threshold:
            // the user is told the rule, not the implementation detail that
            // smooths it.
            radiusMeters = policy.radiusMeters,
            status = status,
            accuracyMeters = fix.accuracyMeters,
            isConfident = fix.accuracyMeters <= policy.maxTrustedAccuracyMeters,
            fixTimestampEpochMillis = fix.timestampEpochMillis,
            isMockProvider = fix.isMock,
        )
    }

    /**
     * Whether [fix] is precise enough to be frozen as an office anchor.
     *
     * A stricter bar than [evaluate] applies, because every future check-in
     * inherits this fix's error. See
     * [GeofencePolicy.maxAnchorAccuracyMeters].
     *
     * @param fix The candidate fix to anchor the office to.
     * @return `true` when it may be saved.
     */
    fun isAcceptableAnchorFix(fix: LocationFix): Boolean =
        fix.accuracyMeters <= policy.maxAnchorAccuracyMeters
}
