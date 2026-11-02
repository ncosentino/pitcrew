package main

import "time"

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
