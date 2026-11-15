package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestGitHubAppTransferredRepositoryUsesCanonicalInstallationAndURL(t *testing.T) {
	privateKey := testGitHubAppPrivateKey(t)
	var requests atomic.Int32
	var metadataID atomic.Int64
	metadataID.Store(42)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		switch r.URL.Path {
		case "/repos/original/project/installation":
			w.Header().Set("Location", "/repositories/42/installation")
			w.WriteHeader(http.StatusMovedPermanently)
		case "/repositories/42/installation":
			fmt.Fprint(w, `{"id":456}`)
		case "/app/installations/456/access_tokens":
			var request struct {
				RepositoryIDs []int64           `json:"repository_ids"`
				Permissions   map[string]string `json:"permissions"`
			}
			if r.Method != http.MethodPost ||
				json.NewDecoder(r.Body).Decode(&request) != nil ||
				len(request.RepositoryIDs) != 1 || request.RepositoryIDs[0] != 42 ||
				len(request.Permissions) != 1 || request.Permissions["metadata"] != "read" {
				t.Error("metadata discovery requested excess scope or the wrong repository")
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			w.WriteHeader(http.StatusCreated)
			fmt.Fprint(w, `{"token":"test-metadata-token"}`)
		case "/repositories/42":
			if r.Header.Get("Authorization") != "Bearer test-metadata-token" {
				t.Error("canonical metadata did not use the scoped installation token")
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			fmt.Fprintf(w, `{"id":%d,"full_name":"replacement/project"}`, metadataID.Load())
		default:
			t.Errorf("unexpected API path %q", r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer server.Close()
	credentials := &githubAppCredentials{
		clientID: "Iv1.example", privateKey: string(testGitHubAppPrivateKeyPEM(t, privateKey)),
		signingKey: privateKey, apiBaseURL: server.URL, httpClient: server.Client(),
		clock:           &fakeClock{current: time.Now().UTC()},
		installationIDs: map[string]int64{"account:original": 123},
	}
	service, err := (githubScaleSetServiceFactory{githubApp: credentials}).
		newService("https://github.com/original/project")
	if err != nil {
		t.Fatal(err)
	}
	if service.(*githubScaleSetService).registrationAccessEndpoint !=
		"/repos/replacement/project/actions/runners/registration-token" {
		t.Fatal("scale-set service retained the transferred repository's old URL")
	}
	id, canonicalURL, err := credentials.installation(
		context.Background(), "https://github.com/original/project",
	)
	if err != nil || id != 456 || canonicalURL != "https://github.com/replacement/project" {
		t.Fatalf("cached canonical installation was not retained: id=%d url=%q error=%v", id, canonicalURL, err)
	}
	if requests.Load() != 4 {
		t.Fatalf("discovery requests = %d, want 4", requests.Load())
	}
	metadataID.Store(43)
	credentials.installationIDs = make(map[string]int64)
	credentials.installationURLs = make(map[string]string)
	if _, _, err := credentials.installation(
		context.Background(), "https://github.com/original/project",
	); err == nil {
		t.Fatal("a different repository identity was accepted after the redirect")
	}
	if len(credentials.installationIDs) != 0 {
		t.Fatal("a failed canonical identity proof was cached")
	}
}

func TestGitHubAppRepositoryRedirectRejectsUntrustedIdentity(t *testing.T) {
	source, err := url.Parse("https://api.github.com/repos/original/project/installation")
	if err != nil {
		t.Fatal(err)
	}
	for _, location := range []string{
		"", "https://example.com/repositories/42/installation",
		"http://api.github.com/repositories/42/installation",
		"https://user@api.github.com/repositories/42/installation",
		"/repositories/42/installation?token=example",
		"/repositories/42/installation#example",
		"/repositories/0/installation",
		"/repositories/042/installation",
		"/repositories/42/actions/runners",
		"/repos/replacement/project/installation",
	} {
		t.Run(location, func(t *testing.T) {
			if _, _, err := githubAppRepositoryRedirect(source, location); err == nil {
				t.Fatal("untrusted repository redirect was accepted")
			}
		})
	}
}

func TestGitHubAppRepositoryDiscoveryBoundsAndRedactsFailures(t *testing.T) {
	for _, test := range []struct {
		name   string
		status int
		body   string
	}{
		{"authorization", http.StatusForbidden, `{"token":"must-not-escape"}`},
		{"oversized", http.StatusOK, strings.Repeat("x", githubAppRepositoryResponseLimit+1)},
		{"malformed", http.StatusOK, "not-json"},
	} {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(test.status)
				fmt.Fprint(w, test.body)
			}))
			defer server.Close()
			requestURL, err := url.Parse(server.URL)
			if err != nil {
				t.Fatal(err)
			}
			var response githubAppInstallationResponse
			err = githubAppBoundedJSONRequest(context.Background(), server.Client(),
				http.MethodGet, requestURL, "test-secret", nil, http.StatusOK, &response)
			if err == nil || strings.Contains(err.Error(), "must-not-escape") ||
				strings.Contains(err.Error(), "test-secret") {
				t.Fatalf("unsafe discovery result: %v", err)
			}
		})
	}
}
