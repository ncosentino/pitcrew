package main

import (
	"context"
	"crypto/rsa"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v4"
)

const (
	githubAppPrivateKeyMaximumBytes = 64 * 1024
	githubAppRequestTimeout         = 15 * time.Second
)

type githubAppCredentials struct {
	clientID         string
	privateKey       string
	signingKey       *rsa.PrivateKey
	apiBaseURL       string
	httpClient       *http.Client
	clock            clock
	mu               sync.Mutex
	installationIDs  map[string]int64
	installationURLs map[string]string
}

type githubAppInstallationResponse struct {
	ID int64 `json:"id"`
}

func loadGitHubAppCredentials(
	clientID string,
	privateKeyPath string,
	appClock clock,
) (*githubAppCredentials, error) {
	clientID = strings.TrimSpace(clientID)
	privateKeyPath = strings.TrimSpace(privateKeyPath)
	if clientID == "" || privateKeyPath == "" {
		return nil, errors.New(
			"GitHub App authentication requires client ID and private key path",
		)
	}
	info, err := os.Stat(privateKeyPath)
	if err != nil {
		return nil, fmt.Errorf("inspect GitHub App private key: %w", err)
	}
	if !info.Mode().IsRegular() || info.Size() < 1 ||
		info.Size() > githubAppPrivateKeyMaximumBytes {
		return nil, errors.New("GitHub App private key must be a bounded regular file")
	}
	privateKeyBytes, err := os.ReadFile(privateKeyPath)
	if err != nil {
		return nil, fmt.Errorf("read GitHub App private key: %w", err)
	}
	defer clear(privateKeyBytes)
	signingKey, err := jwt.ParseRSAPrivateKeyFromPEM(privateKeyBytes)
	if err != nil {
		return nil, errors.New("GitHub App private key is not a valid RSA PEM key")
	}
	if appClock == nil {
		appClock = realClock{}
	}
	return &githubAppCredentials{
		clientID:   clientID,
		privateKey: string(privateKeyBytes),
		signingKey: signingKey,
		apiBaseURL: githubAPIBaseURL,
		httpClient: &http.Client{
			Timeout: githubAppRequestTimeout,
			CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
		clock:           appClock,
		installationIDs: make(map[string]int64),
	}, nil
}

func (a *githubAppCredentials) installationID(
	ctx context.Context,
	registrationURL string,
) (int64, error) {
	installationID, _, err := a.installation(ctx, registrationURL)
	return installationID, err
}

func (a *githubAppCredentials) installation(
	ctx context.Context,
	registrationURL string,
) (int64, string, error) {
	if a == nil {
		return 0, "", errors.New("GitHub App credentials are unavailable")
	}
	cacheKey, endpoint, err := githubAppInstallationEndpoint(registrationURL)
	if err != nil {
		return 0, "", err
	}
	// Repository redirects can cross installation owners. An owner-wide cached
	// installation would bypass discovery of a transferred retirement target.
	if strings.HasPrefix(endpoint, "/repos/") {
		cacheKey = strings.ToLower(endpoint)
	}

	a.mu.Lock()
	defer a.mu.Unlock()
	if installationID := a.installationIDs[cacheKey]; installationID > 0 {
		resolvedURL := a.installationURLs[cacheKey]
		if resolvedURL == "" {
			resolvedURL = registrationURL
		}
		return installationID, resolvedURL, nil
	}
	token, err := a.signedJWT()
	if err != nil {
		return 0, "", err
	}

	base, err := url.Parse(a.apiBaseURL)
	if err != nil ||
		(base.Scheme != "https" && base.Scheme != "http") ||
		base.Host == "" || base.User != nil ||
		base.RawQuery != "" || base.Fragment != "" {
		return 0, "", errors.New("GitHub App API base URL is invalid")
	}
	requestURL := *base
	requestURL.Path = endpoint
	requestURL.RawPath = ""
	request, err := http.NewRequestWithContext(
		ctx,
		http.MethodGet,
		requestURL.String(),
		nil,
	)
	if err != nil {
		return 0, "", fmt.Errorf("create GitHub App installation request: %w", err)
	}
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("User-Agent", "pitcrew-manager")
	request.Header.Set("X-GitHub-Api-Version", "2022-11-28")

	client := *a.httpClient
	client.CheckRedirect = func(_ *http.Request, _ []*http.Request) error {
		return http.ErrUseLastResponse
	}
	response, err := client.Do(request)
	if err != nil {
		return 0, "", fmt.Errorf("discover GitHub App installation: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode == http.StatusMovedPermanently &&
		strings.HasPrefix(endpoint, "/repos/") {
		installationID, canonicalURL, resolveErr := a.resolveRepositoryRedirect(
			ctx, &client, request.URL, response.Header.Get("Location"), token,
		)
		if resolveErr != nil {
			return 0, "", resolveErr
		}
		if a.installationIDs == nil {
			a.installationIDs = make(map[string]int64)
		}
		if a.installationURLs == nil {
			a.installationURLs = make(map[string]string)
		}
		a.installationIDs[cacheKey] = installationID
		a.installationURLs[cacheKey] = canonicalURL
		return installationID, canonicalURL, nil
	}
	if response.StatusCode != http.StatusOK {
		_, _ = io.Copy(
			io.Discard,
			io.LimitReader(response.Body, githubRunnerAccessResponseLimit),
		)
		if response.StatusCode == http.StatusNotFound && strings.HasPrefix(endpoint, "/repos/") {
			installationID, canonicalURL, resolveErr := a.resolveRepositoryNotFound(
				ctx, &client, request.URL, token,
			)
			if resolveErr == nil {
				a.installationIDs[cacheKey] = installationID
				a.installationURLs[cacheKey] = canonicalURL
				return installationID, canonicalURL, nil
			}
			return 0, "", fmt.Errorf("prove GitHub App repository transfer: %w", resolveErr)
		}
		return 0, "", fmt.Errorf("discover GitHub App installation: %w",
			&githubAppHTTPError{statusCode: response.StatusCode})
	}
	var installation githubAppInstallationResponse
	if err := json.NewDecoder(
		io.LimitReader(response.Body, githubRunnerAccessResponseLimit),
	).Decode(&installation); err != nil || installation.ID <= 0 {
		return 0, "", errors.New("GitHub App installation response was invalid")
	}
	if a.installationIDs == nil {
		a.installationIDs = make(map[string]int64)
	}
	if a.installationURLs == nil {
		a.installationURLs = make(map[string]string)
	}
	a.installationIDs[cacheKey] = installation.ID
	a.installationURLs[cacheKey] = registrationURL
	return installation.ID, registrationURL, nil
}

func (a *githubAppCredentials) signedJWT() (string, error) {
	now := a.clock.now().UTC()
	token := jwt.NewWithClaims(jwt.SigningMethodRS256, jwt.MapClaims{
		"iat": now.Add(-time.Minute).Unix(),
		"exp": now.Add(9 * time.Minute).Unix(),
		"iss": a.clientID,
	})
	signed, err := token.SignedString(a.signingKey)
	if err != nil {
		return "", errors.New("sign GitHub App JWT")
	}
	return signed, nil
}

func githubAppInstallationEndpoint(
	registrationURL string,
) (string, string, error) {
	parsed, err := url.Parse(registrationURL)
	if err != nil || parsed.Scheme != "https" ||
		!strings.EqualFold(parsed.Host, "github.com") ||
		parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return "", "", errors.New(
			"GitHub App registration URL must be an HTTPS github.com URL",
		)
	}
	segments := strings.Split(strings.Trim(parsed.Path, "/"), "/")
	switch {
	case len(segments) == 1 && validGitHubPathSegment(segments[0]):
		owner := segments[0]
		return "account:" + strings.ToLower(owner),
			"/orgs/" + url.PathEscape(owner) + "/installation",
			nil
	case len(segments) == 2 &&
		segments[0] != "enterprises" &&
		validGitHubPathSegment(segments[0]) &&
		validGitHubPathSegment(segments[1]):
		owner := segments[0]
		repository := strings.TrimSuffix(segments[1], ".git")
		if !validGitHubPathSegment(repository) {
			break
		}
		return "account:" + strings.ToLower(owner),
			"/repos/" + url.PathEscape(owner) + "/" +
				url.PathEscape(repository) + "/installation",
			nil
	}
	return "", "", errors.New(
		"GitHub App authentication supports repository and organization scopes only",
	)
}

func validGitHubPathSegment(value string) bool {
	return value != "" && value != "." && value != ".." &&
		!strings.ContainsAny(value, `/\`)
}
