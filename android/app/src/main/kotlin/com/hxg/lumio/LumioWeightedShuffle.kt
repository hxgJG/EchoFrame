package com.hxg.lumio

internal fun weightedQueueIndices(weights: List<Int>, enabled: Boolean): List<Int> =
    buildList {
        weights.forEachIndexed { index, weight ->
            // Repeated playlist entries are selection tickets, not copies of media files.
            repeat(if (enabled) weight.coerceIn(1, 10) else 1) { add(index) }
        }
    }
