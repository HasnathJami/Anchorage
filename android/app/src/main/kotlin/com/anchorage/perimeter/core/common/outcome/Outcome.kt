package com.anchorage.perimeter.core.common.outcome

import com.anchorage.perimeter.core.common.error.AppError

/**
 * "It worked, here is the value" **or** "it failed, here is why" — as a
 * value you can return, not an exception you have to catch.
 *
 * This is one of the two types you must understand to read this codebase
 * (the other is [AppError]). Almost every function that can fail returns
 * `Outcome<Something>`.
 *
 * ## Reading it
 *
 * ```kotlin
 * when (val result = repository.findRecordFor(today)) {
 *     is Outcome.Success -> println("got ${result.value}")
 *     is Outcome.Failure -> println("failed because ${result.error}")
 * }
 * ```
 *
 * Because `Outcome` is a **sealed** interface, the compiler knows those are
 * the only two possibilities. If you forget one branch, the code does not
 * compile. That is the whole point.
 *
 * ## Why not just throw exceptions?
 *
 * An exception is invisible in a function's signature. `fun loadAnchor():
 * OfficeAnchor` tells you nothing about the six ways it can fail, so callers
 * forget to handle them and the app crashes in front of a user. Returning
 * `Outcome<OfficeAnchor>` puts the failure in the type, where it cannot be
 * ignored.
 *
 * ## Why not Kotlin's built-in `Result`?
 *
 * Two reasons:
 *
 * 1. `Result` carries a `Throwable`, which invites leaking platform
 *    exceptions (a Play Services `ApiException`, a SQLite error) all the way
 *    up into the UI. `Outcome` pins failures to the closed [AppError]
 *    taxonomy instead, so the compiler can prove every caller handled every
 *    failure mode.
 * 2. `Result` cannot be used as a covariant return type in a sealed
 *    hierarchy without boxing surprises.
 *
 * ## The helper functions below
 *
 * The `when` above is fine, but it gets noisy when you chain several
 * fallible steps. The extension functions at the bottom of this file
 * ([map], [flatMap], [fold] and friends) let you express the common shapes in
 * one line. They all share one rule: **a failure passes straight through
 * untouched.** Only [fold] and [getOrElse] can turn a failure back into a
 * plain value.
 *
 * @param T The type carried on success.
 */
sealed interface Outcome<out T> {

    /**
     * The happy path.
     *
     * @property value What the operation produced.
     */
    data class Success<out T>(val value: T) : Outcome<T>

    /**
     * The failure path.
     *
     * It is `Outcome<Nothing>` rather than `Outcome<T>` so that a failure can
     * be returned from *any* function regardless of its success type —
     * `Nothing` is a subtype of everything in Kotlin. This is what lets
     * [map] and [flatMap] return `this` on the failure branch.
     *
     * @property error Why it failed, from the closed [AppError] taxonomy.
     */
    data class Failure(val error: AppError) : Outcome<Nothing>

    /** True when this is a [Success]. */
    val isSuccess: Boolean get() = this is Success

    /** True when this is a [Failure]. */
    val isFailure: Boolean get() = this is Failure
}

/**
 * Unwraps the value, or gives you `null` if this failed.
 *
 * Use when the failure genuinely does not matter to the caller — typically in
 * the UI, where "no value" and "failed to load" render identically.
 */
fun <T> Outcome<T>.getOrNull(): T? = when (this) {
    is Outcome.Success -> value
    is Outcome.Failure -> null
}

/** The mirror of [getOrNull]: the error, or `null` if this succeeded. */
fun <T> Outcome<T>.errorOrNull(): AppError? = when (this) {
    is Outcome.Success -> null
    is Outcome.Failure -> error
}

/**
 * Unwraps the value, or computes a substitute from the error.
 *
 * @param fallback What to return instead, given the error that occurred.
 */
fun <T> Outcome<T>.getOrElse(fallback: (AppError) -> @UnsafeVariance T): T = when (this) {
    is Outcome.Success -> value
    is Outcome.Failure -> fallback(error)
}

/**
 * Transforms the value inside, leaving a failure untouched.
 *
 * Use when the transformation itself **cannot fail**:
 * `anchorOutcome.map { it.label }`.
 *
 * @param transform Converts the success value. Never called on a failure.
 */
inline fun <T, R> Outcome<T>.map(transform: (T) -> R): Outcome<R> = when (this) {
    is Outcome.Success -> Outcome.Success(transform(value))
    is Outcome.Failure -> this
}

/**
 * Chains another step that can *itself* fail, short-circuiting on the first
 * failure.
 *
 * Use when the next step returns an `Outcome` too. Without this you would get
 * a nested `Outcome<Outcome<T>>`:
 *
 * ```kotlin
 * locationTracker.currentFix(timeout).flatMap { fix ->
 *     repository.append(recordFrom(fix))   // also returns an Outcome
 * }
 * ```
 *
 * If `currentFix` fails, `transform` is never called and the original error
 * is what comes out.
 *
 * @param transform The next fallible step. Never called on a failure.
 */
inline fun <T, R> Outcome<T>.flatMap(transform: (T) -> Outcome<R>): Outcome<R> = when (this) {
    is Outcome.Success -> transform(value)
    is Outcome.Failure -> this
}

/**
 * Rewrites the error, leaving a success untouched.
 *
 * Used by data-layer adapters to translate one error vocabulary into another
 * — for example turning a storage failure into a location failure when that
 * is what the caller actually cares about.
 *
 * @param transform Converts the error. Never called on a success.
 */
inline fun <T> Outcome<T>.mapError(transform: (AppError) -> AppError): Outcome<T> = when (this) {
    is Outcome.Success -> this
    is Outcome.Failure -> Outcome.Failure(transform(error))
}

/**
 * Collapses both branches into a single ordinary value.
 *
 * This is how an `Outcome` finally *leaves* the Outcome world — typically in
 * a ViewModel, turning a result into UI state.
 *
 * @param onSuccess Produces the result from the value.
 * @param onFailure Produces the result from the error.
 */
inline fun <T, R> Outcome<T>.fold(
    onSuccess: (T) -> R,
    onFailure: (AppError) -> R,
): R = when (this) {
    is Outcome.Success -> onSuccess(value)
    is Outcome.Failure -> onFailure(error)
}

/**
 * Runs a side effect on success and returns the receiver unchanged, so calls
 * stay chainable: `outcome.onSuccess { log(it) }.onFailure { report(it) }`.
 *
 * @param action Performed only when this is a success.
 */
inline fun <T> Outcome<T>.onSuccess(action: (T) -> Unit): Outcome<T> = apply {
    if (this is Outcome.Success) action(value)
}

/**
 * Runs a side effect on failure and returns the receiver unchanged.
 *
 * @param action Performed only when this is a failure.
 */
inline fun <T> Outcome<T>.onFailure(action: (AppError) -> Unit): Outcome<T> = apply {
    if (this is Outcome.Failure) action(error)
}

/** Reads better at a call site than `Outcome.Success(x)`: `x.asSuccess()`. */
fun <T> T.asSuccess(): Outcome<T> = Outcome.Success(this)

/** Reads better at a call site than `Outcome.Failure(e)`: `e.asFailure()`. */
fun AppError.asFailure(): Outcome<Nothing> = Outcome.Failure(this)
