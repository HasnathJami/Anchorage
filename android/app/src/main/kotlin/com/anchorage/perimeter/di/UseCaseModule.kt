package com.anchorage.perimeter.di

import com.anchorage.perimeter.domain.geo.DistanceCalculator
import com.anchorage.perimeter.domain.geo.HaversineDistanceCalculator
import com.anchorage.perimeter.domain.policy.AttendanceWindow
import com.anchorage.perimeter.domain.policy.GeofenceEvaluator
import com.anchorage.perimeter.domain.policy.GeofencePolicy
import com.anchorage.perimeter.domain.port.AttendanceRepository
import com.anchorage.perimeter.domain.port.IdGenerator
import com.anchorage.perimeter.domain.port.LocationTracker
import com.anchorage.perimeter.domain.port.OfficeAnchorRepository
import com.anchorage.perimeter.domain.port.TimeProvider
import com.anchorage.perimeter.domain.usecase.CaptureOfficeAnchorUseCase
import com.anchorage.perimeter.domain.usecase.ClearOfficeAnchorUseCase
import com.anchorage.perimeter.domain.usecase.MarkAttendanceUseCase
import com.anchorage.perimeter.domain.usecase.PlaceOfficeAnchorUseCase
import com.anchorage.perimeter.domain.usecase.ObserveAttendanceHistoryUseCase
import com.anchorage.perimeter.domain.usecase.ObserveAttendanceStatusUseCase
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

/**
 * Assembles the domain.
 *
 * The use cases have no framework annotations of their own - they are plain
 * constructor-injected Kotlin classes that a test can `new` in one line. This
 * module is the single place that knows how to build them, which is what keeps
 * `:core:domain` free of any dependency on Hilt.
 *
 * The policy objects ([GeofencePolicy], [AttendanceWindow]) are provided rather
 * than defaulted at each call site, so a future "office profile" feature can
 * make them per-tenant by changing this file alone.
 */
@Module
@InstallIn(SingletonComponent::class)
object UseCaseModule {

    @Provides
    @Singleton
    fun provideGeofencePolicy(): GeofencePolicy = GeofencePolicy.Default

    @Provides
    @Singleton
    fun provideAttendanceWindow(): AttendanceWindow = AttendanceWindow.Default

    @Provides
    @Singleton
    fun provideDistanceCalculator(): DistanceCalculator = HaversineDistanceCalculator

    @Provides
    @Singleton
    fun provideGeofenceEvaluator(
        distanceCalculator: DistanceCalculator,
        policy: GeofencePolicy,
    ): GeofenceEvaluator = GeofenceEvaluator(distanceCalculator, policy)

    @Provides
    fun provideObserveAttendanceStatusUseCase(
        officeAnchorRepository: OfficeAnchorRepository,
        locationTracker: LocationTracker,
        attendanceRepository: AttendanceRepository,
        geofenceEvaluator: GeofenceEvaluator,
        timeProvider: TimeProvider,
        window: AttendanceWindow,
    ) = ObserveAttendanceStatusUseCase(
        officeAnchorRepository = officeAnchorRepository,
        locationTracker = locationTracker,
        attendanceRepository = attendanceRepository,
        geofenceEvaluator = geofenceEvaluator,
        timeProvider = timeProvider,
        window = window,
    )

    @Provides
    fun provideCaptureOfficeAnchorUseCase(
        locationTracker: LocationTracker,
        officeAnchorRepository: OfficeAnchorRepository,
        geofenceEvaluator: GeofenceEvaluator,
        policy: GeofencePolicy,
    ) = CaptureOfficeAnchorUseCase(
        locationTracker = locationTracker,
        officeAnchorRepository = officeAnchorRepository,
        geofenceEvaluator = geofenceEvaluator,
        policy = policy,
    )

    @Provides
    fun provideMarkAttendanceUseCase(
        officeAnchorRepository: OfficeAnchorRepository,
        attendanceRepository: AttendanceRepository,
        locationTracker: LocationTracker,
        geofenceEvaluator: GeofenceEvaluator,
        timeProvider: TimeProvider,
        idGenerator: IdGenerator,
        window: AttendanceWindow,
    ) = MarkAttendanceUseCase(
        officeAnchorRepository = officeAnchorRepository,
        attendanceRepository = attendanceRepository,
        locationTracker = locationTracker,
        geofenceEvaluator = geofenceEvaluator,
        timeProvider = timeProvider,
        idGenerator = idGenerator,
        window = window,
    )

    @Provides
    fun providePlaceOfficeAnchorUseCase(
        officeAnchorRepository: OfficeAnchorRepository,
        timeProvider: TimeProvider,
    ) = PlaceOfficeAnchorUseCase(officeAnchorRepository, timeProvider)

    @Provides
    fun provideClearOfficeAnchorUseCase(
        officeAnchorRepository: OfficeAnchorRepository,
    ) = ClearOfficeAnchorUseCase(officeAnchorRepository)

    @Provides
    fun provideObserveAttendanceHistoryUseCase(
        attendanceRepository: AttendanceRepository,
    ) = ObserveAttendanceHistoryUseCase(attendanceRepository)
}
