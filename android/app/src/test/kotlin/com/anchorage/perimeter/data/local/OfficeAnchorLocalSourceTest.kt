package com.anchorage.perimeter.data.local

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.doublePreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.floatPreferencesKey
import androidx.datastore.preferences.core.longPreferencesKey
import com.anchorage.perimeter.core.common.outcome.Outcome
import com.anchorage.perimeter.data.local.datastore.OfficeAnchorLocalSource
import com.anchorage.perimeter.domain.model.GeoPoint
import com.anchorage.perimeter.domain.model.OfficeAnchor
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * Exercised against a real DataStore writing to a temp file rather than a
 * mock, so the test proves the anchor actually survives serialisation - which
 * is the only failure mode that would matter in production.
 */
class OfficeAnchorLocalSourceTest {

    @get:Rule
    val temporaryFolder = TemporaryFolder()

    private var fileCounter = 0

    /**
     * DataStore insists on creating its own file, so we hand it a path inside
     * a temp directory rather than a pre-created (and therefore zero-byte,
     * and therefore "corrupt") file.
     */
    private fun newStore(scope: CoroutineScope): DataStore<Preferences> =
        PreferenceDataStoreFactory.create(
            scope = scope,
            produceFile = {
                File(temporaryFolder.root, "anchor-${fileCounter++}.preferences_pb")
            },
        )

    @Test
    fun `reports no anchor before anything is saved`() = runTest {
        val source = OfficeAnchorLocalSource(newStore(backgroundScope))

        val outcome = source.observe().first()

        assertThat((outcome as Outcome.Success).value).isNull()
    }

    @Test
    fun `round-trips every field of a saved anchor`() = runTest {
        val source = OfficeAnchorLocalSource(newStore(backgroundScope))
        val anchor = OfficeAnchor(
            point = GeoPoint(23.780887, 90.414391),
            accuracyMeters = 4.5f,
            capturedAtEpochMillis = 1_724_800_000_000L,
            label = "Gulshan HQ",
        )

        assertThat(source.save(anchor)).isEqualTo(Outcome.Success(Unit))

        assertThat((source.observe().first() as Outcome.Success).value).isEqualTo(anchor)
    }

    @Test
    fun `clear removes the anchor`() = runTest {
        val source = OfficeAnchorLocalSource(newStore(backgroundScope))
        source.save(OfficeAnchor(GeoPoint(1.0, 2.0), 3f, 4L))

        source.clear()

        assertThat((source.observe().first() as Outcome.Success).value).isNull()
    }

    @Test
    fun `a partially written anchor is treated as no anchor`() = runTest {
        val store = newStore(backgroundScope)
        val source = OfficeAnchorLocalSource(store)

        // Simulate a process death between the latitude and longitude writes.
        store.edit { it[doublePreferencesKey("office_latitude")] = 23.78 }

        assertThat((source.observe().first() as Outcome.Success).value).isNull()
    }

    @Test
    fun `an out-of-range persisted coordinate degrades to not-configured instead of crashing`() =
        runTest {
            val store = newStore(backgroundScope)
            val source = OfficeAnchorLocalSource(store)

            store.edit { preferences ->
                preferences[doublePreferencesKey("office_latitude")] = 999.0
                preferences[doublePreferencesKey("office_longitude")] = 90.0
                preferences[floatPreferencesKey("office_accuracy_meters")] = 5f
                preferences[longPreferencesKey("office_captured_at")] = 1L
            }

            val outcome = source.observe().first()

            assertThat(outcome).isInstanceOf(Outcome.Success::class.java)
            assertThat((outcome as Outcome.Success).value).isNull()
        }

    @Test
    fun `a saved anchor without a label falls back to the default`() = runTest {
        val store = newStore(backgroundScope)
        val source = OfficeAnchorLocalSource(store)

        store.edit { preferences ->
            preferences[doublePreferencesKey("office_latitude")] = 23.780887
            preferences[doublePreferencesKey("office_longitude")] = 90.414391
            preferences[floatPreferencesKey("office_accuracy_meters")] = 5f
            preferences[longPreferencesKey("office_captured_at")] = 99L
        }

        val anchor = (source.observe().first() as Outcome.Success).value

        assertThat(anchor?.label).isEqualTo(OfficeAnchor.DEFAULT_LABEL)
    }
}
