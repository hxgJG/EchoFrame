package com.hxg.lumio

import org.junit.Assert.*
import org.junit.Test

class LumioWeightedShuffleTest {
    @Test fun defaultWeightsKeepOriginalQueue() {
        assertEquals(listOf(0, 1, 2), weightedQueueIndices(listOf(1, 1, 1), true))
    }

    @Test fun shuffleAllocatesTicketsInProportionToWeights() {
        val indices = weightedQueueIndices(listOf(1, 5, 10), true)
        assertEquals(16, indices.size)
        assertEquals(1, indices.count { it == 0 })
        assertEquals(5, indices.count { it == 1 })
        assertEquals(10, indices.count { it == 2 })
    }

    @Test fun sequentialPlaybackIgnoresWeightsAndValuesAreBounded() {
        assertEquals(listOf(0, 1, 2), weightedQueueIndices(listOf(1, 5, 10), false))
        assertEquals(11, weightedQueueIndices(listOf(0, 999), true).size)
        assertTrue(weightedQueueIndices(emptyList(), true).isEmpty())
    }
}
