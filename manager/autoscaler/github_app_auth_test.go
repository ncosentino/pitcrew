package main

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v4"
)

func TestGitHubAppInstallationEndpoint(t *testing.T) {
	tests := []struct {
		url      string
		cacheKey string
		endpoint string
		valid    bool
	}{
		{
			url:      "https://github.com/example/repository",
			cacheKey: "account:example",
			endpoint: "/repos/example/repository/installation",
			valid:    true,
		},
		{
			url:      "https://github.com/example",
			cacheKey: "account:example",
			endpoint: "/orgs/example/installation",
			valid:    true,
		},
		{url: "https://github.com/enterprises/example", valid: false},
		{url: "https://example.com/example/repository", valid: false},
	}
	for _, test := range tests {
		t.Run(test.url, func(t *testing.T) {
			cacheKey, endpoint, err := githubAppInstallationEndpoint(test.url)
			if (err == nil) != test.valid {
				t.Fatalf("valid=%t, got error %v", test.valid, err)
			}
			if test.valid &&
				(cacheKey != test.cacheKey || endpoint != test.endpoint) {
				t.Fatalf(
					"got cache=%q endpoint=%q, want cache=%q endpoint=%q",
					cacheKey,
					endpoint,
					test.cacheKey,
					test.endpoint,
				)
			}
		})
	}
}

func TestGitHubAppInstallationDiscoveryCachesByOwner(t *testing.T) {
	privateKey := testGitHubAppPrivateKey(t)
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(
		func(response http.ResponseWriter, request *http.Request) {
			requests.Add(1)
			token := request.Header.Get("Authorization")
			if len(token) < len("Bearer ")+1 {
				t.Error("installation discovery omitted bearer JWT")
				response.WriteHeader(http.StatusUnauthorized)
				return
			}
			parsed, err := jwt.Parse(
				token[len("Bearer "):],
				func(token *jwt.Token) (any, error) {
					return &privateKey.PublicKey, nil
				},
			)
			if err != nil || !parsed.Valid {
				t.Errorf("installation discovery JWT is invalid: %v", err)
				response.WriteHeader(http.StatusUnauthorized)
				return
			}
			response.Header().Set("Content-Type", "application/json")
			_, _ = response.Write([]byte(`{"id":12345}`))
		},
	))
	defer server.Close()

	credentials := &githubAppCredentials{
		clientID:        "Iv1.example",
		privateKey:      string(testGitHubAppPrivateKeyPEM(t, privateKey)),
		signingKey:      privateKey,
		apiBaseURL:      server.URL,
		httpClient:      server.Client(),
		clock:           &fakeClock{current: time.Now().UTC()},
		installationIDs: make(map[string]int64),
	}
	first, err := credentials.installationID(
		context.Background(),
		"https://github.com/example/one",
	)
	if err != nil {
		t.Fatal(err)
	}
	second, err := credentials.installationID(
		context.Background(),
		"https://github.com/example/two",
	)
	if err != nil {
		t.Fatal(err)
	}
	if first != 12345 || second != 12345 {
		t.Fatalf("unexpected installation IDs: %d %d", first, second)
	}
	if requests.Load() != 1 {
		t.Fatalf("installation discovery requests = %d, want 1", requests.Load())
	}
	service, err := (githubScaleSetServiceFactory{
		githubApp: credentials,
	}).newService("https://github.com/example/three")
	if err != nil {
		t.Fatal(err)
	}
	githubService, ok := service.(*githubScaleSetService)
	if !ok || githubService.registrationAccessEnabled ||
		githubService.accessToken != "" {
		t.Fatalf("factory did not select GitHub App authentication: %#v", service)
	}
}

func TestLoadGitHubAppCredentialsRejectsInvalidKey(t *testing.T) {
	path := filepath.Join(t.TempDir(), "invalid.pem")
	if err := os.WriteFile(path, []byte("not-a-key"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadGitHubAppCredentials(
		"Iv1.example",
		path,
		&fakeClock{current: time.Now().UTC()},
	); err == nil {
		t.Fatal("invalid GitHub App key was accepted")
	}
}

func testGitHubAppPrivateKey(t *testing.T) *rsa.PrivateKey {
	t.Helper()
	privateKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	return privateKey
}

func testGitHubAppPrivateKeyPEM(
	t *testing.T,
	privateKey *rsa.PrivateKey,
) []byte {
	t.Helper()
	return pem.EncodeToMemory(&pem.Block{
		Type:  "RSA PRIVATE KEY",
		Bytes: x509.MarshalPKCS1PrivateKey(privateKey),
	})
}
