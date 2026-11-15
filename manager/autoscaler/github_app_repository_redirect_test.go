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

func TestGitHubAppHiddenTransferRequiresScopedMetadataProof(t *testing.T) {
	for _, test := range []struct {
		name     string
		status   int
		location string
		metadata string
		cache    bool
		success  bool
	}{
		{"hidden-transfer", 404, "/repositories/42", `{"id":42,"full_name":"replacement/project"}`, true, true},
		{"direct-metadata-alias", 404, "direct", `{"id":42,"full_name":"replacement/project"}`, true, true},
		{"wrong-id", 404, "/repositories/42", `{"id":43,"full_name":"replacement/project"}`, true, false},
		{"wrong-repository", 404, "/repositories/42", `{"id":42,"full_name":"replacement/other"}`, true, false},
		{"untrusted-origin", 404, "https://example.com/repositories/42", "", true, false},
		{"installation-redirect-path", 404, "/repositories/42/installation", "", true, false},
		{"unavailable", 404, "", "", true, false},
		{"no-authenticated-candidate", 404, "/repositories/42", "", false, false},
		{"forbidden-not-a-transfer", 403, "/repositories/42", "", true, false},
		{"metadata-forbidden", 404, "forbidden", "", true, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			privateKey := testGitHubAppPrivateKey(t)
			var proofRequests atomic.Int32
			var unrelatedProofs atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch r.URL.Path {
				case "/repos/earlier/unrelated/installation":
					fmt.Fprint(w, `{"id":123}`)
				case "/repos/replacement/project/installation":
					fmt.Fprint(w, `{"id":456}`)
				case "/repos/original/project/installation":
					w.WriteHeader(test.status)
				case "/app/installations/456/access_tokens":
					proofRequests.Add(1)
					var scope struct {
						Repositories  []string          `json:"repositories"`
						RepositoryIDs []int64           `json:"repository_ids"`
						Permissions   map[string]string `json:"permissions"`
					}
					if r.Method != http.MethodPost || json.NewDecoder(r.Body).Decode(&scope) != nil ||
						len(scope.Repositories) != 1 || scope.Repositories[0] != "project" ||
						len(scope.RepositoryIDs) != 0 || len(scope.Permissions) != 1 ||
						scope.Permissions["metadata"] != "read" {
						t.Error("hidden-transfer proof requested excess token scope")
						w.WriteHeader(http.StatusBadRequest)
						return
					}
					w.WriteHeader(http.StatusCreated)
					fmt.Fprint(w, `{"token":"private-proof-token"}`)
				case "/app/installations/123/access_tokens":
					unrelatedProofs.Add(1)
					w.WriteHeader(http.StatusCreated)
					fmt.Fprint(w, `{"token":"unrelated-scoped-token"}`)
				case "/repos/original/project":
					if r.Header.Get("Authorization") == "Bearer unrelated-scoped-token" {
						w.WriteHeader(http.StatusNotFound)
						return
					}
					if r.Header.Get("Authorization") != "Bearer private-proof-token" {
						t.Error("original repository metadata did not use the candidate-scoped token")
					}
					if test.location == "" {
						w.WriteHeader(http.StatusNotFound)
						return
					}
					if test.location == "direct" {
						fmt.Fprint(w, test.metadata)
						return
					}
					if test.location == "forbidden" {
						w.WriteHeader(http.StatusForbidden)
						fmt.Fprint(w, `{"token":"private-proof-token"}`)
						return
					}
					w.Header().Set("Location", test.location)
					w.WriteHeader(http.StatusMovedPermanently)
				case "/repositories/42":
					if r.Header.Get("Authorization") != "Bearer private-proof-token" {
						t.Error("redirected metadata did not preserve the scoped token")
					}
					fmt.Fprint(w, test.metadata)
				default:
					t.Errorf("unexpected proof request %s", r.URL.Path)
					w.WriteHeader(http.StatusNotFound)
				}
			}))
			defer server.Close()
			credentials := &githubAppCredentials{
				clientID: "Iv1.example", signingKey: privateKey,
				apiBaseURL: server.URL, httpClient: server.Client(),
				clock: &fakeClock{current: time.Now().UTC()},
			}
			if test.name == "hidden-transfer" {
				if _, _, err := credentials.installation(context.Background(),
					"https://github.com/earlier/unrelated"); err != nil {
					t.Fatal(err)
				}
			}
			if test.cache {
				if _, _, err := credentials.installation(context.Background(),
					"https://github.com/replacement/project"); err != nil {
					t.Fatal(err)
				}
			}
			id, canonical, err := credentials.installation(context.Background(),
				"https://github.com/original/project")
			if (err == nil) != test.success {
				t.Fatalf("success=%t, got error %v", test.success, err)
			}
			if err != nil && (strings.Contains(err.Error(), "private-proof-token") ||
				strings.Contains(err.Error(), "example.com")) {
				t.Fatal("proof error disclosed token or untrusted redirect")
			}
			if test.success {
				if id != 456 || canonical != "https://github.com/replacement/project" {
					t.Fatalf("wrong authenticated identity: %d %q", id, canonical)
				}
				if _, _, err := credentials.installation(context.Background(),
					"https://github.com/original/project"); err != nil || proofRequests.Load() != 1 {
					t.Fatal("successful proof was not cached")
				}
			} else if credentials.installationIDs["/repos/original/project/installation"] != 0 {
				t.Fatal("failed proof was cached")
			}
			if (!test.cache || test.status != 404) && proofRequests.Load() != 0 {
				t.Fatal("proof ran without an authenticated candidate or without HTTP 404")
			}
			if test.name == "hidden-transfer" && unrelatedProofs.Load() != 1 {
				t.Fatal("an unrelated candidate's HTTP 404 was not skipped exactly once")
			}
		})
	}
}
