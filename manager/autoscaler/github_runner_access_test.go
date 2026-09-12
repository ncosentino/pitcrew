package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestGitHubRunnerRegistrationAccessEndpoint(t *testing.T) {
	tests := map[string]string{
		"https://github.com/example/repository":  "/repos/example/repository/actions/runners/registration-token",
		"https://github.com/example":             "/orgs/example/actions/runners/registration-token",
		"https://github.com/enterprises/example": "/enterprises/example/actions/runners/registration-token",
	}
	for registrationURL, expected := range tests {
		actual, err := githubRunnerRegistrationAccessEndpoint(registrationURL)
		if err != nil {
			t.Fatalf("%s: %v", registrationURL, err)
		}
		if actual != expected {
			t.Fatalf("%s: expected %q, got %q", registrationURL, expected, actual)
		}
	}
}

func TestGitHubRunnerRegistrationAccessEndpointRejectsUntrustedURLs(t *testing.T) {
	for _, registrationURL := range []string{
		"http://github.com/example/repository",
		"https://example.com/example/repository",
		"https://github.com/example/repository?redirect=1",
		"https://github.com/example/repository/extra",
	} {
		if _, err := githubRunnerRegistrationAccessEndpoint(registrationURL); err == nil {
			t.Fatalf("expected %q to be rejected", registrationURL)
		}
	}
}

func TestCheckGitHubRunnerRegistrationAccess(t *testing.T) {
	tests := []struct {
		name     string
		status   int
		headers  map[string]string
		body     string
		expected error
	}{
		{name: "authorized", status: http.StatusCreated, body: `{"token":"secret"}`},
		{
			name:     "unauthorized",
			status:   http.StatusUnauthorized,
			body:     `{"message":"secret-provider-body"}`,
			expected: errGitHubRunnerCredentialRejected,
		},
		{name: "forbidden", status: http.StatusForbidden, expected: errGitHubRunnerPermissionDenied},
		{
			name:     "organization authorization required",
			status:   http.StatusForbidden,
			headers:  map[string]string{"X-GitHub-SSO": "required; url=https://example.invalid"},
			expected: errGitHubRunnerOrganizationAccess,
		},
		{
			name:     "rate limited forbidden",
			status:   http.StatusForbidden,
			headers:  map[string]string{"X-RateLimit-Remaining": "0"},
			expected: errGitHubRunnerRateLimited,
		},
		{name: "not found", status: http.StatusNotFound, expected: errGitHubRunnerNotFound},
		{name: "rate limited", status: http.StatusTooManyRequests, expected: errGitHubRunnerRateLimited},
		{name: "malformed success", status: http.StatusCreated, body: `{"token":""}`, expected: errGitHubRunnerResponse},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewTLSServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
				if request.Method != http.MethodPost {
					t.Fatalf("expected POST, got %s", request.Method)
				}
				if request.URL.Path != "/repos/example/repository/actions/runners/registration-token" {
					t.Fatalf("unexpected path %q", request.URL.Path)
				}
				if request.Header.Get("Authorization") != "Bearer test-token" {
					t.Fatal("authorization header was not set")
				}
				for key, value := range test.headers {
					writer.Header().Set(key, value)
				}
				writer.WriteHeader(test.status)
				_, _ = writer.Write([]byte(test.body))
			}))
			defer server.Close()

			err := checkGitHubRunnerRegistrationAccess(
				context.Background(),
				server.Client(),
				server.URL,
				"/repos/example/repository/actions/runners/registration-token",
				"test-token",
			)
			if !errors.Is(err, test.expected) {
				t.Fatalf("expected %v, got %v", test.expected, err)
			}
			if err != nil && strings.Contains(err.Error(), "secret") {
				t.Fatal("credential response leaked through the error")
			}
		})
	}
}

func TestCheckGitHubRunnerRegistrationAccessRejectsRedirect(t *testing.T) {
	destinationReached := false
	destination := httptest.NewTLSServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		destinationReached = true
	}))
	defer destination.Close()
	redirect := httptest.NewTLSServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		http.Redirect(writer, request, destination.URL, http.StatusTemporaryRedirect)
	}))
	defer redirect.Close()

	client := redirect.Client()
	client.CheckRedirect = func(_ *http.Request, _ []*http.Request) error {
		return http.ErrUseLastResponse
	}
	err := checkGitHubRunnerRegistrationAccess(
		context.Background(),
		client,
		redirect.URL,
		"/repos/example/repository/actions/runners/registration-token",
		"test-token",
	)
	if !errors.Is(err, errGitHubRunnerResponse) {
		t.Fatalf("expected invalid response, got %v", err)
	}
	if destinationReached {
		t.Fatal("credential-bearing request followed a redirect")
	}
}

func TestGitHubRunnerAccessExitCode(t *testing.T) {
	tests := map[error]int{
		nil:                               0,
		errGitHubRunnerCredentialRejected: 3,
		errGitHubRunnerNotFound:           4,
		errGitHubRunnerRateLimited:        5,
		context.DeadlineExceeded:          6,
		errGitHubRunnerPermissionDenied:   7,
		errGitHubRunnerOrganizationAccess: 8,
		errGitHubRunnerResponse:           1,
	}
	for err, expected := range tests {
		if actual := githubRunnerAccessExitCode(err); actual != expected {
			t.Fatalf("expected %d for %v, got %d", expected, err, actual)
		}
	}
}
