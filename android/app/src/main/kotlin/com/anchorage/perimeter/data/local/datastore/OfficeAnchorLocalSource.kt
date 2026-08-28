package com.anchorage.perimeter.data.local.datastore

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.doublePreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.floatPreferencesKey
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import com.anchorage.perimeter.core.common.error.AppError
import com.anchorage.perimeter.core.common.outcome.Outcome
import com.anchorage.perimeter.domain.model.AnchorSource
import com.anchorage.perimeter.domain.model.GeoPoint
import com.anchorage.perimeter.domain.model.OfficeAnchor
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.map
import java.io.IOException
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Reads and writes the single office anchor to Proto-less DataStore.
 *
 * DataStore rather than SharedPreferences because the anchor is read as a
 * *stream*: the Attendance screen must react the instant a new office is
 * captured, and `SharedPreferences.OnSharedPreferenceChangeListener` is a
 * callback-and-leak API by comparison. DataStore also gives transactional
 * writes, so a crash mid-save can never leave a latitude without its longitude.
 *
 * Note the [catch] on the read path: DataStore signals a corrupt or unreadable
 * file with an `IOException` *inside the flow*. Left unhandled it would
 * propagate to the UI collector and kill the screen; here it becomes a typed
 * [AppError.Storage] value the screen can render as a banner.
 */
@Singleton
class OfficeAnchorLocalSource @Inject constructor(
    private val dataStore: DataStore<Preferences>,
) {

    fun observe(): Flow<Outcome<OfficeAnchor?>> = dataStore.data
        .map { preferences -> Outcome.Success(preferences.toAnchorOrNull()) as Outcome<OfficeAnchor?> }
        .catch { throwable ->
            emit(
                Outcome.Failure(
                    when (throwable) {
                        is IOException -> AppError.Storage.ReadFailed(throwable)
                        else -> AppError.Storage.Corrupted(
                            detail = throwable.message.orEmpty(),
                            cause = throwable,
                        )
                    },
                ),
            )
        }

    suspend fun save(anchor: OfficeAnchor): Outcome<Unit> = runStorage(write = true) {
        dataStore.edit { preferences ->
            preferences[KEY_LATITUDE] = anchor.point.latitude
            preferences[KEY_LONGITUDE] = anchor.point.longitude
            preferences[KEY_ACCURACY] = anchor.accuracyMeters
            preferences[KEY_CAPTURED_AT] = anchor.capturedAtEpochMillis
            preferences[KEY_LABEL] = anchor.label
            preferences[KEY_SOURCE] = anchor.source.name
        }
    }

    suspend fun clear(): Outcome<Unit> = runStorage(write = true) {
        dataStore.edit { preferences ->
            preferences.remove(KEY_LATITUDE)
            preferences.remove(KEY_LONGITUDE)
            preferences.remove(KEY_ACCURACY)
            preferences.remove(KEY_CAPTURED_AT)
            preferences.remove(KEY_LABEL)
            preferences.remove(KEY_SOURCE)
        }
    }

    /**
     * Returns `null` unless *every* field is present. A partially written
     * anchor is treated as no anchor at all rather than as a coordinate with
     * silent zeroes standing in for the missing halves.
     */
    private fun Preferences.toAnchorOrNull(): OfficeAnchor? {
        val latitude = this[KEY_LATITUDE] ?: return null
        val longitude = this[KEY_LONGITUDE] ?: return null
        val accuracy = this[KEY_ACCURACY] ?: return null
        val capturedAt = this[KEY_CAPTURED_AT] ?: return null

        return runCatching {
            OfficeAnchor(
                point = GeoPoint(latitude, longitude),
                accuracyMeters = accuracy,
                capturedAtEpochMillis = capturedAt,
                label = this[KEY_LABEL] ?: OfficeAnchor.DEFAULT_LABEL,
                // Anchors written before provenance was recorded were all
                // GPS captures, so a missing key reads as GpsFix rather than
                // forcing an upgrade to look like a hand-placed pin.
                source = this[KEY_SOURCE]
                    ?.let { name -> AnchorSource.entries.firstOrNull { it.name == name } }
                    ?: AnchorSource.GpsFix,
            )
        }.getOrNull() // Out-of-range persisted values degrade to "not configured".
    }

    private inline fun runStorage(write: Boolean, block: () -> Unit): Outcome<Unit> = try {
        block()
        Outcome.Success(Unit)
    } catch (io: IOException) {
        Outcome.Failure(
            if (write) AppError.Storage.WriteFailed(io) else AppError.Storage.ReadFailed(io),
        )
    }

    private companion object {
        val KEY_LATITUDE = doublePreferencesKey("office_latitude")
        val KEY_LONGITUDE = doublePreferencesKey("office_longitude")
        val KEY_ACCURACY = floatPreferencesKey("office_accuracy_meters")
        val KEY_CAPTURED_AT = longPreferencesKey("office_captured_at")
        val KEY_LABEL = stringPreferencesKey("office_label")
        val KEY_SOURCE = stringPreferencesKey("office_source")
    }
}
