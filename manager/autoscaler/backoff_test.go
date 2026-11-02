package main

import (
	"testing"
	"time"
)

func TestBoundedExponentialBackoff(t *testing.T) {
	tests := []struct {
		name     string
		base     time.Duration
		maximum  time.Duration
		failures int
		expected time.Duration
	}{
		{
			name:     "no failures",
			base:     time.Minute,
			maximum:  15 * time.Minute,
			failures: 0,
			expected: 0,
		},
		{
			name:     "first failure",
			base:     time.Minute,
			maximum:  15 * time.Minute,
			failures: 1,
			expected: time.Minute,
		},
		{
			name:     "progressive failure",
			base:     time.Minute,
			maximum:  15 * time.Minute,
			failures: 4,
			expected: 8 * time.Minute,
		},
		{
			name:     "bounded failure",
			base:     time.Minute,
			maximum:  15 * time.Minute,
			failures: 5,
			expected: 15 * time.Minute,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			actual := boundedExponentialBackoff(
				test.base,
				test.maximum,
				test.failures,
			)
			if actual != test.expected {
				t.Fatalf("backoff = %s, want %s", actual, test.expected)
			}
		})
	}
}
