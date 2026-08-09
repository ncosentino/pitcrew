package main

import (
	"errors"
	"testing"

	"github.com/ncosentino/pitcrew/manager/admission"
)

func TestExitCodeForError(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want int
	}{
		{
			name: "budget withheld",
			err:  admission.ErrBudgetExceeded,
			want: 3,
		},
		{
			name: "lease already absent",
			err:  admission.ErrLeaseNotFound,
			want: 4,
		},
		{
			name: "profile policy mismatch",
			err:  admission.ErrUnknownProfile,
			want: 5,
		},
		{
			name: "lease state mismatch",
			err:  admission.ErrLeaseExpired,
			want: 5,
		},
		{
			name: "coordinator failure",
			err:  errors.New("coordinator unavailable"),
			want: 1,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := exitCodeForError(test.err); got != test.want {
				t.Fatalf("exitCodeForError(%v) = %d, want %d", test.err, got, test.want)
			}
		})
	}
}
