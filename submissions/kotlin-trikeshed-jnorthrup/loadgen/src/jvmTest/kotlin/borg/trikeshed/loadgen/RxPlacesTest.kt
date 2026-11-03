package borg.trikeshed.loadgen

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertSame

/** The window queue's ownership rule, step by step: a place belongs to one connection generation of one user. */
class RxPlacesTest {
    fun user(local: Int) = Vu(local, local, 0, 1).apply { gen = 1; connected = true }

    @Test
    fun aUserWhoTimedOutAndReconnectedNeverInheritsItsOldPlace() {
        val v = user(0)
        val places = RxPlaces(arrayOf(v))
        places.queue(v) // its readiness found no free window (a pool of one)
        // The request's deadline passes: the connection closes (closeFd voids the place), the user reconnects and its new
        // socket's watch is armed before any window comes back.
        v.rxQueued = false
        v.connected = false
        v.gen = 2
        v.connected = true
        v.polling = true
        assertNull(places.next(), "the old place is void: no RECV on the new socket while its watch is armed")
        assertEquals(0, places.size)
        // The new connection's own readiness takes a fresh place, which is honoured.
        v.polling = false
        places.queue(v)
        assertSame(v, places.next())
    }

    @Test
    fun placesKeepTheirOrderAndAUserHoldsOneAtMost() {
        val a = user(0)
        val b = user(1)
        val c = user(2)
        val places = RxPlaces(arrayOf(a, b, c))
        places.queue(a)
        places.queue(b)
        places.queue(c)
        assertFailsWith<IllegalStateException> { places.queue(b) }
        b.rxQueued = false
        b.connected = false // b closed while waiting and has not reconnected
        assertSame(a, places.next())
        assertSame(c, places.next(), "b's void place is dropped")
        assertNull(places.next())
        val d = user(3).apply { receiving = true }
        assertFailsWith<IllegalStateException> { RxPlaces(arrayOf(d)).queue(d) }
    }
}
