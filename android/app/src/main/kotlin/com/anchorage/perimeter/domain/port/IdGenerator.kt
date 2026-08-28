package com.anchorage.perimeter.domain.port

import java.util.UUID

/**
 * Injectable identity source, so a test can assert on a *known* record id
 * instead of matching a wildcard.
 */
fun interface IdGenerator {
    fun newId(): String
}

/** Production implementation. */
object UuidIdGenerator : IdGenerator {
    override fun newId(): String = UUID.randomUUID().toString()
}
