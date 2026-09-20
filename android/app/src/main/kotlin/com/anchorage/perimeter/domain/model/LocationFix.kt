package com.anchorage.perimeter.domain.model

/**
 * One answer from the phone's GPS: "you are *here*, give or take this much,
 * and I worked that out at this moment."
 *
 * A "fix" is the standard word for a single positioning result. The phone
 * produces a new one roughly every two seconds while the attendance screen is
 * open.
 *
 * ## Why accuracy is part of the model, not a side note
 *
 * GPS never reports a point — it reports a *circle*. [accuracyMeters] is the
 * radius of that circle at 68% confidence, which is what Android's
 * `Location.getAccuracy()` returns. Indoors it is routinely 30–50 m; outdoors
 * with a clear sky it can be 3 m.
 *
 * That matters enormously here, because the office geofence is only 50 m
 * across. A fix that says "you are at the office, ±40 m" is not evidence of
 * anything. So Anchorage refuses to save an office anchor, or admit a
 * check-in, on a fix it does not trust — see
 * [com.anchorage.perimeter.domain.policy.GeofencePolicy].
 *
 * @property point Where the phone believes it is.
 * @property accuracyMeters The radius of uncertainty around [point], in
 *   metres. **Smaller is better.** Never negative.
 * @property timestampEpochMillis When this fix was produced, in milliseconds
 *   since 1 Jan 1970 UTC. Used to show the user how fresh the reading is.
 * @property isMock True when the fix came from a mock-location provider
 *   rather than real satellites. Anchorage *reports* this rather than
 *   blocking it — every emulator reports mocked fixes, so blocking would make
 *   the app untestable on the device most reviewers use. The flag is stored
 *   with the attendance record so the audit trail can flag it later.
 */
data class LocationFix(
    val point: GeoPoint,
    val accuracyMeters: Float,
    val timestampEpochMillis: Long,
    val isMock: Boolean = false,
) {
    init {
        require(accuracyMeters >= 0f) { "accuracy cannot be negative but was $accuracyMeters" }
    }
}
