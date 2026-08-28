package com.anchorage.perimeter.core.common.outcome

import com.anchorage.perimeter.core.common.error.AppError
import com.google.common.truth.Truth.assertThat
import org.junit.Test

class OutcomeTest {

    private val failure: Outcome<Int> = Outcome.Failure(AppError.Storage.ReadFailed())

    @Test
    fun `map transforms only the success branch`() {
        assertThat(Outcome.Success(2).map { it * 3 }).isEqualTo(Outcome.Success(6))
        assertThat(failure.map { it * 3 }).isEqualTo(failure)
    }

    @Test
    fun `flatMap short-circuits on the first failure`() {
        var reached = false
        val result = failure.flatMap { reached = true; Outcome.Success(it) }

        assertThat(reached).isFalse()
        assertThat(result).isEqualTo(failure)
    }

    @Test
    fun `fold collapses both branches`() {
        assertThat(Outcome.Success(7).fold({ "ok $it" }, { "err" })).isEqualTo("ok 7")
        assertThat(failure.fold({ "ok" }, { "err" })).isEqualTo("err")
    }

    @Test
    fun `mapError rewrites the error vocabulary`() {
        val translated = failure.mapError { AppError.Unexpected("translated") }

        assertThat((translated as Outcome.Failure).error)
            .isEqualTo(AppError.Unexpected("translated"))
    }

    @Test
    fun `accessors behave as documented`() {
        assertThat(Outcome.Success(1).getOrNull()).isEqualTo(1)
        assertThat(failure.getOrNull()).isNull()
        assertThat(failure.errorOrNull()).isInstanceOf(AppError.Storage.ReadFailed::class.java)
        assertThat(failure.getOrElse { -1 }).isEqualTo(-1)
        assertThat(Outcome.Success(1).isSuccess).isTrue()
        assertThat(failure.isFailure).isTrue()
    }

    @Test
    fun `side effects fire on the matching branch only`() {
        var successes = 0
        var failures = 0

        Outcome.Success(1).onSuccess { successes++ }.onFailure { failures++ }
        failure.onSuccess { successes++ }.onFailure { failures++ }

        assertThat(successes).isEqualTo(1)
        assertThat(failures).isEqualTo(1)
    }
}
