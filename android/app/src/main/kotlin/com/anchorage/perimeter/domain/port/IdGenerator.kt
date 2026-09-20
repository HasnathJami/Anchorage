package com.anchorage.perimeter.domain.port

import java.util.UUID

/**
 * "Give me a unique id", as something you can inject.
 *
 * Same reasoning as [TimeProvider]: a random UUID generated inline would make
 * tests assert on a wildcard. Behind this port a test hands over a generator
 * that returns `"record-1"`, and can then assert on the *exact* record that
 * was written.
 */
fun interface IdGenerator {
    /** A fresh identifier, unique among all previously returned ones. */
    fun newId(): String
}

/** The real implementation: a random type-4 UUID. */
object UuidIdGenerator : IdGenerator {
    override fun newId(): String = UUID.randomUUID().toString()
}
