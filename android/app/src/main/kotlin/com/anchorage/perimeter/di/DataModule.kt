package com.anchorage.perimeter.di

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.preferencesDataStoreFile
import androidx.room.Room
import com.anchorage.perimeter.core.common.dispatcher.DispatcherProvider
import com.anchorage.perimeter.core.common.dispatcher.StandardDispatcherProvider
import com.anchorage.perimeter.data.local.room.AnchorageDatabase
import com.anchorage.perimeter.data.local.room.AttendanceDao
import com.anchorage.perimeter.data.location.AndroidLocationEnvironment
import com.anchorage.perimeter.data.location.FusedLocationTracker
import com.anchorage.perimeter.data.map.OsmTileSource
import com.anchorage.perimeter.data.location.LocationEnvironment
import com.anchorage.perimeter.data.repository.AttendanceRepositoryImpl
import com.anchorage.perimeter.data.repository.OfficeAnchorRepositoryImpl
import com.anchorage.perimeter.domain.port.AttendanceRepository
import com.anchorage.perimeter.domain.port.IdGenerator
import com.anchorage.perimeter.domain.port.LocationTracker
import com.anchorage.perimeter.domain.port.MapTileSource
import com.anchorage.perimeter.domain.port.OfficeAnchorRepository
import com.anchorage.perimeter.domain.port.SystemTimeProvider
import com.anchorage.perimeter.domain.port.TimeProvider
import com.anchorage.perimeter.domain.port.UuidIdGenerator
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationServices
import dagger.Binds
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

/**
 * **Where the abstract meets the concrete.** This module tells Hilt which
 * real class to hand over whenever something asks for a domain port.
 *
 * ## Dependency injection in thirty seconds
 *
 * [com.anchorage.perimeter.domain.usecase.MarkAttendanceUseCase] asks for a
 * [LocationTracker] — an interface. It does not know, and must not know, that
 * the real one talks to Google Play Services. This file is the single place
 * that makes the connection:
 *
 * ```
 * asked for            gets built as
 * ─────────────────────────────────────────────
 * LocationTracker  →   FusedLocationTracker
 * AttendanceRepository → AttendanceRepositoryImpl
 * ```
 *
 * Swap a line here and the whole app uses a different implementation, with no
 * other file touched. That is the entire point of pointing dependencies at
 * interfaces.
 *
 * ## Why `@Binds` and not `@Provides`
 *
 * `@Binds` is used wherever an interface maps one-to-one onto a class. It
 * compiles to a direct reference instead of a generated factory method, and
 * it states the substitution in one greppable line.
 *
 * ## How tests replace all of this
 *
 * A test swaps this entire module out with `@TestInstallIn` and supplies
 * fakes. That is only possible because the graph is expressed against
 * interfaces rather than concrete types.
 */
@Module
@InstallIn(SingletonComponent::class)
abstract class DataBindingsModule {

    /** The GPS. See [FusedLocationTracker]. */
    @Binds
    @Singleton
    abstract fun bindLocationTracker(impl: FusedLocationTracker): LocationTracker

    /** The permission and location-toggle checks. */
    @Binds
    @Singleton
    abstract fun bindLocationEnvironment(impl: AndroidLocationEnvironment): LocationEnvironment

    /** The saved office, in DataStore. */
    @Binds
    @Singleton
    abstract fun bindOfficeAnchorRepository(impl: OfficeAnchorRepositoryImpl): OfficeAnchorRepository

    /** The attendance history, in Room. */
    @Binds
    @Singleton
    abstract fun bindAttendanceRepository(impl: AttendanceRepositoryImpl): AttendanceRepository

    /** Map imagery, from OpenStreetMap. */
    @Binds
    @Singleton
    abstract fun bindMapTileSource(impl: OsmTileSource): MapTileSource
}

/**
 * Builds the framework objects Hilt cannot construct by itself.
 *
 * [DataBindingsModule] above handles "this interface means that class".
 * This module handles the other case: objects that need a factory call, a
 * builder, or a `Context` — things Hilt cannot work out from a constructor.
 */
@Module
@InstallIn(SingletonComponent::class)
object DataProvidersModule {

    /** The DataStore file name. Changing it orphans every saved office. */
    private const val PREFERENCES_NAME = "anchorage_office_anchor"

    /** The real threads. Tests substitute a single test dispatcher. */
    @Provides
    @Singleton
    fun provideDispatcherProvider(): DispatcherProvider = StandardDispatcherProvider

    /** The real clock. Tests substitute a fixed one. */
    @Provides
    @Singleton
    fun provideTimeProvider(): TimeProvider = SystemTimeProvider()

    /** Real UUIDs. Tests substitute a counter. */
    @Provides
    @Singleton
    fun provideIdGenerator(): IdGenerator = UuidIdGenerator

    /**
     * Play Services' location client.
     *
     * @param context Application-scoped, so holding it cannot leak a screen.
     */
    @Provides
    @Singleton
    fun provideFusedLocationClient(
        @ApplicationContext context: Context,
    ): FusedLocationProviderClient = LocationServices.getFusedLocationProviderClient(context)

    /**
     * The preferences store that holds the office anchor.
     *
     * The scope uses a `SupervisorJob` so that one failed write cannot cancel
     * the scope and take every later read down with it.
     */
    @Provides
    @Singleton
    fun providePreferencesDataStore(
        @ApplicationContext context: Context,
        dispatchers: DispatcherProvider,
    ): DataStore<Preferences> = PreferenceDataStoreFactory.create(
        scope = kotlinx.coroutines.CoroutineScope(dispatchers.io + kotlinx.coroutines.SupervisorJob()),
        produceFile = { context.preferencesDataStoreFile(PREFERENCES_NAME) },
    )

    /** The Room database holding attendance history. */
    @Provides
    @Singleton
    fun provideDatabase(@ApplicationContext context: Context): AnchorageDatabase =
        Room.databaseBuilder(context, AnchorageDatabase::class.java, AnchorageDatabase.NAME)
            // No destructive fallback: losing an attendance log to a schema
            // bump would be a data-integrity incident, not a convenience.
            .build()

    /**
     * Not `@Singleton`: the DAO is a cheap accessor on the database, which is
     * itself the singleton.
     */
    @Provides
    fun provideAttendanceDao(database: AnchorageDatabase): AttendanceDao = database.attendanceDao()
}
