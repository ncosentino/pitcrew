package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestDeleteRunnerUsesExactBoundedRequest(t *testing.T) {
	token := "test-token"
	server := httptest.NewServer(http.HandlerFunc(func(
		writer http.ResponseWriter,
		request *http.Request,
	) {
		if request.Method != http.MethodDelete {
			t.Fatalf("method = %s", request.Method)
		}
		if request.URL.Path != "/repos/example/project/actions/runners/77" {
			t.Fatalf("path = %s", request.URL.Path)
		}
		if request.Header.Get("Authorization") != "Bearer "+token {
			t.Fatal("authorization header was missing")
		}
		writer.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	client := &http.Client{Timeout: time.Second}
	if err := deleteRunner(
		context.Background(),
		client,
		server.URL,
		"/repos/example/project/actions/runners",
		77,
		token,
	); err != nil {
		t.Fatalf("delete runner: %v", err)
	}
}

func TestDeleteRunnerTreatsAlreadyAbsentAsSuccess(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(
		writer http.ResponseWriter,
		_ *http.Request,
	) {
		writer.WriteHeader(http.StatusNotFound)
	}))
	defer server.Close()

	if err := deleteRunner(
		context.Background(),
		server.Client(),
		server.URL,
		"/orgs/example/actions/runners",
		1,
		"test-token",
	); err != nil {
		t.Fatalf("already absent runner was not idempotent: %v", err)
	}
}

func TestDeleteRunnerRejectsRedirectedDeletion(t *testing.T) {
	var redirected atomic.Bool
	target := httptest.NewServer(http.HandlerFunc(func(
		writer http.ResponseWriter,
		_ *http.Request,
	) {
		redirected.Store(true)
		writer.WriteHeader(http.StatusNoContent)
	}))
	defer target.Close()
	source := httptest.NewServer(http.HandlerFunc(func(
		writer http.ResponseWriter,
		request *http.Request,
	) {
		http.Redirect(writer, request, target.URL, http.StatusTemporaryRedirect)
	}))
	defer source.Close()

	client := &http.Client{
		Timeout: time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	err := deleteRunner(
		context.Background(),
		client,
		source.URL,
		"/repos/example/project/actions/runners",
		77,
		"test-token",
	)
	if err == nil || redirected.Load() {
		t.Fatalf(
			"redirected deletion was accepted: err=%v redirected=%t",
			err,
			redirected.Load(),
		)
	}
}

func TestDeleteRunnerRejectsUntrustedInputsBeforeHTTP(t *testing.T) {
	client := &http.Client{
		Transport: roundTripperFunc(func(*http.Request) (*http.Response, error) {
			t.Fatal("invalid input reached HTTP")
			return nil, nil
		}),
	}
	cases := []struct {
		name     string
		endpoint string
		runnerID int64
		token    string
	}{
		{name: "host override", endpoint: "https://example.test/actions/runners", runnerID: 1, token: "token"},
		{name: "path traversal", endpoint: "/repos/example/../actions/runners", runnerID: 1, token: "token"},
		{name: "missing id", endpoint: "/repos/example/project/actions/runners", runnerID: 0, token: "token"},
		{name: "missing token", endpoint: "/repos/example/project/actions/runners", runnerID: 1},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			err := deleteRunner(
				context.Background(),
				client,
				"https://api.github.test",
				testCase.endpoint,
				testCase.runnerID,
				testCase.token,
			)
			if err == nil ||
				(testCase.token != "" && strings.Contains(err.Error(), testCase.token)) {
				t.Fatalf("unexpected validation result: %v", err)
			}
		})
	}
}

func TestRunDeleteRejectsUnexpectedArguments(t *testing.T) {
	t.Setenv("ACCESS_TOKEN", "test-token")
	err := runDelete([]string{
		"--endpoint", "/repos/example/project/actions/runners",
		"--runner-id", "77",
		"unexpected",
	})
	if err == nil {
		t.Fatal("unexpected positional argument was accepted")
	}
}

type roundTripperFunc func(*http.Request) (*http.Response, error)

func (f roundTripperFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return f(request)
}
