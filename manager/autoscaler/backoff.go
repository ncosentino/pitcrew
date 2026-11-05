package main

import (
	"crypto/sha256"
	"time"
)

func deterministicRetryJitter(identity string, window time.Duration) time.Duration {
	windowSeconds := int(window / time.Second)
	if windowSeconds <= 0 {
		return 0
	}
	sum := sha256.Sum256([]byte(identity))
	value := int(sum[0])<<8 | int(sum[1])
	return time.Duration(value%windowSeconds) * time.Second
}

func boundedExponentialBackoff(
	base time.Duration,
	maximum time.Duration,
	consecutiveFailures int,
) time.Duration {
	if base <= 0 || consecutiveFailures <= 0 {
		return 0
	}
	if maximum <= 0 {
		return base
	}
	if base >= maximum {
		return maximum
	}

	delay := base
	for attempt := 1; attempt < consecutiveFailures; attempt++ {
		if delay >= maximum || delay > maximum/2 {
			return maximum
		}
		delay *= 2
	}
	if delay > maximum {
		return maximum
	}
	return delay
}
