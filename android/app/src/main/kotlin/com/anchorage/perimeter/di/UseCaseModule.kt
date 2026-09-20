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
 * **Assembles the domain.** This module knows how to build every use case.
 *
 * ## Why the use cases need a module at all
 *
 * Look at any use case in `domain/usecase/`: it has **no framework
 * annotations**. No `@Inject`, no `@Singleton`, nothing. They are plain
 * Kotlin classes a test can construct in one line:
 *
 * ```kotlin
 * val useCase = MarkAttendanceUseCase(fakeRepo, fakeAttendance, fakeTracker, ...)
 * ```
 *
 * That purity is the point — it is what keeps the domain layer free of any
 * dependency on Hilt, and what the architecture test enforces. The cost is
 * that somebody has to tell Hilt how to build them, and this file is that
 * somebody. One place, explicitly.
 *
 * ## Why the policies are provided rather than defaulted
 *
 * [GeofencePolicy] and [AttendanceWindow] both have perfectly good defaults,
 * so every use case could just take them. They are provided here instead so
 * that a future "office profile" feature — a per-tenant radius, a per-site
 * check-in window — becomes a change to this file alone.
 *
 * ## Singleton or not?
 *
 * The policies, the distance calculator and the evaluator are `@Singleton`:
 * they are stateless and immutable, so one instance is enough. The use cases
 * are **not**, because they are cheap to build and holding one alive longer
 * than its caller buys nothing.
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
