package com.anchorage.perimeter.core.common.outcome

import com.anchorage.perimeter.core.common.error.AppError

/**
 * A total, exception-free result type used across every architectural seam.
 *
 * Anchorage treats "failure" as data rather than control flow. Kotlin's
 * built-in [Result] was rejected for two reasons: it carries a `Throwable`
 * (which invites leaking platform exceptions upward) and it cannot be used as
 * a covariant return type in a sealed hierarchy without boxing surprises.
 * [Outcome] instead pins failures to the closed [AppError] taxonomy, so the
 * compiler can prove that every caller handled every failure mode.
 */
sealed interface Outcome<out T> {

    data class Success<out T>(val value: T) : Outcome<T>

    data class Failure(val error: AppError) : Outcome<Nothing>

    val isSuccess: Boolean get() = this is Success

    val isFailure: Boolean get() = this is Failure
}

/** Returns the value, or `null` when this is a [Outcome.Failure]. */
fun <T> Outcome<T>.getOrNull(): T? = when (this) {
    is Outcome.Success -> value
    is Outcome.Failure -> null
}

/** Returns the error, or `null` when this is a [Outcome.Success]. */
fun <T> Outcome<T>.errorOrNull(): AppError? = when (this) {
    is Outcome.Success -> null
    is Outcome.Failure -> error
}

/** Returns the value, or [fallback] when this is a [Outcome.Failure]. */
fun <T> Outcome<T>.getOrElse(fallback: (AppError) -> @UnsafeVariance T): T = when (this) {
    is Outcome.Success -> value
    is Outcome.Failure -> fallback(error)
}

/** Transforms a successful value while leaving failures untouched. */
inline fun <T, R> Outcome<T>.map(transform: (T) -> R): Outcome<R> = when (this) {
    is Outcome.Success -> Outcome.Success(transform(value))
    is Outcome.Failure -> this
}

/** Chains another fallible step, short-circuiting on the first failure. */
inline fun <T, R> Outcome<T>.flatMap(transform: (T) -> Outcome<R>): Outcome<R> = when (this) {
    is Outcome.Success -> transform(value)
    is Outcome.Failure -> this
}

/** Rewrites the failure - used by adapters to translate error vocabularies. */
inline fun <T> Outcome<T>.mapError(transform: (AppError) -> AppError): Outcome<T> = when (this) {
    is Outcome.Success -> this
    is Outcome.Failure -> Outcome.Failure(transform(error))
}

/** Collapses both branches into a single value. */
inline fun <T, R> Outcome<T>.fold(
    onSuccess: (T) -> R,
    onFailure: (AppError) -> R,
): R = when (this) {
    is Outcome.Success -> onSuccess(value)
    is Outcome.Failure -> onFailure(error)
}

/** Side effect on success; returns the receiver so calls stay chainable. */
inline fun <T> Outcome<T>.onSuccess(action: (T) -> Unit): Outcome<T> = apply {
    if (this is Outcome.Success) action(value)
}

/** Side effect on failure; returns the receiver so calls stay chainable. */
inline fun <T> Outcome<T>.onFailure(action: (AppError) -> Unit): Outcome<T> = apply {
    if (this is Outcome.Failure) action(error)
}

/** Convenience constructors that read better than the class names at call sites. */
fun <T> T.asSuccess(): Outcome<T> = Outcome.Success(this)

fun AppError.asFailure(): Outcome<Nothing> = Outcome.Failure(this)
