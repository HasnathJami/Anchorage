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
 * Binds every domain port to its production implementation.
 *
 * `@Binds` is preferred over `@Provides` wherever an interface maps 1:1 to a
 * class: it compiles to a direct reference instead of a generated factory, and
 * it makes the substitution explicit and greppable. Tests replace this whole
 * module with `@TestInstallIn`, which is only possible because the graph is
 * expressed against interfaces rather than concrete types.
 */
@Module
@InstallIn(SingletonComponent::class)
abstract class DataBindingsModule {

    @Binds
    @Singleton
    abstract fun bindLocationTracker(impl: FusedLocationTracker): LocationTracker

    @Binds
    @Singleton
    abstract fun bindLocationEnvironment(impl: AndroidLocationEnvironment): LocationEnvironment

    @Binds
    @Singleton
    abstract fun bindOfficeAnchorRepository(impl: OfficeAnchorRepositoryImpl): OfficeAnchorRepository

    @Binds
    @Singleton
    abstract fun bindAttendanceRepository(impl: AttendanceRepositoryImpl): AttendanceRepository

    @Binds
    @Singleton
    abstract fun bindMapTileSource(impl: OsmTileSource): MapTileSource
}

/** Constructs the framework objects Hilt cannot build by itself. */
@Module
@InstallIn(SingletonComponent::class)
object DataProvidersModule {

    private const val PREFERENCES_NAME = "anchorage_office_anchor"

    @Provides
    @Singleton
    fun provideDispatcherProvider(): DispatcherProvider = StandardDispatcherProvider

    @Provides
    @Singleton
    fun provideTimeProvider(): TimeProvider = SystemTimeProvider()

    @Provides
    @Singleton
    fun provideIdGenerator(): IdGenerator = UuidIdGenerator

    @Provides
    @Singleton
    fun provideFusedLocationClient(
        @ApplicationContext context: Context,
    ): FusedLocationProviderClient = LocationServices.getFusedLocationProviderClient(context)

    @Provides
    @Singleton
    fun providePreferencesDataStore(
        @ApplicationContext context: Context,
        dispatchers: DispatcherProvider,
    ): DataStore<Preferences> = PreferenceDataStoreFactory.create(
        scope = kotlinx.coroutines.CoroutineScope(dispatchers.io + kotlinx.coroutines.SupervisorJob()),
        produceFile = { context.preferencesDataStoreFile(PREFERENCES_NAME) },
    )

    @Provides
    @Singleton
    fun provideDatabase(@ApplicationContext context: Context): AnchorageDatabase =
        Room.databaseBuilder(context, AnchorageDatabase::class.java, AnchorageDatabase.NAME)
            // No destructive fallback: losing an attendance log to a schema
            // bump would be a data-integrity incident, not a convenience.
            .build()

    @Provides
    fun provideAttendanceDao(database: AnchorageDatabase): AttendanceDao = database.attendanceDao()
}
