package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
)

const githubAppRepositoryResponseLimit = 64 * 1024

type githubAppHTTPError struct {
	statusCode int
	location   string
}

func (e *githubAppHTTPError) Error() string {
	return fmt.Sprintf("GitHub App API request returned HTTP status %d", e.statusCode)
}

func githubAppRepositoryRedirect(
	source *url.URL,
	location string,
) (*url.URL, int64, error) {
	return githubAppRepositoryIdentityRedirect(source, location, true)
}

func githubAppRepositoryIdentityRedirect(
	source *url.URL,
	location string,
	installation bool,
) (*url.URL, int64, error) {
	redirect, err := url.Parse(location)
	if err != nil || location == "" {
		return nil, 0, errors.New("GitHub App repository redirect was invalid")
	}
	redirect = source.ResolveReference(redirect)
	if redirect.Scheme != source.Scheme ||
		!strings.EqualFold(redirect.Host, source.Host) ||
		redirect.User != nil || redirect.RawQuery != "" ||
		redirect.Fragment != "" || redirect.RawPath != "" {
		return nil, 0, errors.New("GitHub App repository redirect crossed its trusted origin")
	}
	segments := strings.Split(strings.Trim(redirect.Path, "/"), "/")
	expectedSegments := 2
	if installation {
		expectedSegments = 3
	}
	if len(segments) != expectedSegments || segments[0] != "repositories" ||
		(installation && segments[2] != "installation") {
		return nil, 0, errors.New("GitHub App repository redirect had an unsupported path")
	}
	repositoryID, err := strconv.ParseInt(segments[1], 10, 64)
	if err != nil || repositoryID <= 0 ||
		strconv.FormatInt(repositoryID, 10) != segments[1] {
		return nil, 0, errors.New("GitHub App repository redirect had an invalid repository ID")
	}
	return redirect, repositoryID, nil
}

func githubAppBoundedJSONRequest(
	ctx context.Context,
	client *http.Client,
	method string,
	requestURL *url.URL,
	token string,
	body []byte,
	expectedStatus int,
	result any,
) error {
	request, err := http.NewRequestWithContext(
		ctx, method, requestURL.String(), bytes.NewReader(body),
	)
	if err != nil {
		return errors.New("create GitHub App repository discovery request")
	}
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("User-Agent", "pitcrew-manager")
	request.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	if len(body) > 0 {
		request.Header.Set("Content-Type", "application/json")
	}
	response, err := client.Do(request)
	if err != nil {
		return errors.New("GitHub App repository discovery transport failed")
	}
	defer response.Body.Close()
	if response.StatusCode != expectedStatus {
		return &githubAppHTTPError{
			statusCode: response.StatusCode,
			location:   response.Header.Get("Location"),
		}
	}
	data, err := io.ReadAll(io.LimitReader(
		response.Body, githubAppRepositoryResponseLimit+1,
	))
	defer clear(data)
	if err != nil || len(data) > githubAppRepositoryResponseLimit ||
		json.Unmarshal(data, result) != nil {
		return errors.New("GitHub App repository discovery response was invalid")
	}
	return nil
}

func (a *githubAppCredentials) resolveRepositoryRedirect(
	ctx context.Context,
	client *http.Client,
	source *url.URL,
	location string,
	jwt string,
) (int64, string, error) {
	redirect, repositoryID, err := githubAppRepositoryRedirect(source, location)
	if err != nil {
		return 0, "", err
	}
	var installation githubAppInstallationResponse
	if err := githubAppBoundedJSONRequest(
		ctx, client, http.MethodGet, redirect, jwt, nil, http.StatusOK, &installation,
	); err != nil {
		return 0, "", err
	}
	if installation.ID <= 0 {
		return 0, "", errors.New("GitHub App redirected installation response was invalid")
	}
	tokenURL := *source
	tokenURL.Path = fmt.Sprintf("/app/installations/%d/access_tokens", installation.ID)
	tokenURL.RawPath = ""
	token, err := githubAppMetadataToken(ctx, client, &tokenURL, jwt, struct {
		RepositoryIDs []int64           `json:"repository_ids"`
		Permissions   map[string]string `json:"permissions"`
	}{
		RepositoryIDs: []int64{repositoryID},
		Permissions:   map[string]string{"metadata": "read"},
	})
	if err != nil {
		return 0, "", err
	}
	defer func() { token = "" }()
	repositoryURL := *source
	repositoryURL.Path = fmt.Sprintf("/repositories/%d", repositoryID)
	repositoryURL.RawPath = ""
	var repository githubAppRepositoryMetadata
	if err := githubAppBoundedJSONRequest(
		ctx, client, http.MethodGet, &repositoryURL, token, nil,
		http.StatusOK, &repository,
	); err != nil {
		return 0, "", err
	}
	canonicalURL, err := repository.canonicalURL(repositoryID)
	return installation.ID, canonicalURL, err
}

func githubAppMetadataToken(
	ctx context.Context,
	client *http.Client,
	tokenURL *url.URL,
	jwt string,
	scope any,
) (string, error) {
	body, err := json.Marshal(scope)
	if err != nil {
		return "", errors.New("encode GitHub App metadata token request")
	}
	var access githubRunnerAccessResponse
	if err := githubAppBoundedJSONRequest(
		ctx, client, http.MethodPost, tokenURL, jwt, body,
		http.StatusCreated, &access,
	); err != nil {
		return "", err
	}
	if access.Token == "" {
		return "", errors.New("GitHub App metadata token response was invalid")
	}
	return access.Token, nil
}

type githubAppRepositoryMetadata struct {
	ID       int64  `json:"id"`
	FullName string `json:"full_name"`
}

func (repository githubAppRepositoryMetadata) canonicalURL(repositoryID int64) (string, error) {
	segments := strings.Split(repository.FullName, "/")
	if repositoryID <= 0 || repository.ID != repositoryID || len(segments) != 2 ||
		!validGitHubPathSegment(segments[0]) ||
		!validGitHubPathSegment(segments[1]) {
		return "", errors.New("GitHub App canonical repository identity did not match its redirect")
	}
	canonicalURL := "https://github.com/" + url.PathEscape(segments[0]) +
		"/" + url.PathEscape(segments[1])
	if _, _, err := githubAppInstallationEndpoint(canonicalURL); err != nil {
		return "", errors.New("GitHub App canonical repository URL was invalid")
	}
	return canonicalURL, nil
}

// Installation discovery can conceal a transfer with 404 even when repository
// metadata redirects. Only already-authenticated repositories provide candidates.
// The caller holds a.mu; this path must not recursively discover installations.
func (a *githubAppCredentials) resolveRepositoryNotFound(
	ctx context.Context,
	client *http.Client,
	source *url.URL,
	jwt string,
) (int64, string, error) {
	candidates := make([]string, 0, len(a.installationURLs))
	for key := range a.installationURLs {
		if strings.HasPrefix(key, "/repos/") && a.installationIDs[key] > 0 {
			candidates = append(candidates, key)
		}
	}
	sort.Strings(candidates)
	for _, key := range candidates {
		candidate := a.installationURLs[key]
		_, endpoint, err := githubAppInstallationEndpoint(candidate)
		if err != nil || !strings.HasPrefix(endpoint, "/repos/") {
			return 0, "", errors.New("GitHub App cached repository identity was invalid")
		}
		fullName := strings.TrimSuffix(strings.TrimPrefix(endpoint, "/repos/"), "/installation")
		repositoryName := strings.Split(fullName, "/")[1]
		tokenURL := *source
		tokenURL.Path = fmt.Sprintf("/app/installations/%d/access_tokens", a.installationIDs[key])
		tokenURL.RawPath = ""
		token, err := githubAppMetadataToken(ctx, client, &tokenURL, jwt, struct {
			Repositories []string          `json:"repositories"`
			Permissions  map[string]string `json:"permissions"`
		}{
			Repositories: []string{repositoryName},
			Permissions:  map[string]string{"metadata": "read"},
		})
		if err != nil {
			return 0, "", fmt.Errorf("create repository identity proof token: %w", err)
		}
		canonicalURL, err := githubAppProveRepositoryAlias(ctx, client, source, token, candidate)
		token = ""
		if err != nil {
			var status *githubAppHTTPError
			if errors.As(err, &status) && status.statusCode == http.StatusNotFound {
				continue
			}
			return 0, "", err
		}
		return a.installationIDs[key], canonicalURL, nil
	}
	return 0, "", &githubAppHTTPError{statusCode: http.StatusNotFound}
}

func githubAppProveRepositoryAlias(
	ctx context.Context,
	client *http.Client,
	source *url.URL,
	token string,
	candidate string,
) (string, error) {
	metadataURL := *source
	metadataURL.Path = strings.TrimSuffix(source.Path, "/installation")
	metadataURL.RawPath = ""
	var repository githubAppRepositoryMetadata
	err := githubAppBoundedJSONRequest(ctx, client, http.MethodGet,
		&metadataURL, token, nil, http.StatusOK, &repository)
	repositoryID := repository.ID
	if err != nil {
		var status *githubAppHTTPError
		if !errors.As(err, &status) || status.statusCode != http.StatusMovedPermanently {
			return "", err
		}
		redirect, id, redirectErr := githubAppRepositoryIdentityRedirect(
			&metadataURL, status.location, false,
		)
		if redirectErr != nil {
			return "", redirectErr
		}
		repositoryID = id
		if err := githubAppBoundedJSONRequest(ctx, client, http.MethodGet,
			redirect, token, nil, http.StatusOK, &repository); err != nil {
			return "", err
		}
	}
	canonicalURL, err := repository.canonicalURL(repositoryID)
	if err != nil {
		return "", err
	}
	if !strings.EqualFold(canonicalURL, candidate) {
		return "", errors.New("GitHub App repository metadata did not match its scoped candidate")
	}
	return canonicalURL, nil
}
