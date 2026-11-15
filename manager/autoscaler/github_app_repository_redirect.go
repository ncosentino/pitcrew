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
	"strconv"
	"strings"
)

const githubAppRepositoryResponseLimit = 64 * 1024

type githubAppHTTPError struct {
	statusCode int
}

func (e *githubAppHTTPError) Error() string {
	return fmt.Sprintf("GitHub App API request returned HTTP status %d", e.statusCode)
}

func githubAppRepositoryRedirect(
	source *url.URL,
	location string,
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
	if len(segments) != 3 || segments[0] != "repositories" ||
		segments[2] != "installation" {
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
		return &githubAppHTTPError{statusCode: response.StatusCode}
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
	body, err := json.Marshal(struct {
		RepositoryIDs []int64           `json:"repository_ids"`
		Permissions   map[string]string `json:"permissions"`
	}{
		RepositoryIDs: []int64{repositoryID},
		Permissions:   map[string]string{"metadata": "read"},
	})
	if err != nil {
		return 0, "", errors.New("encode GitHub App metadata token request")
	}
	var access githubRunnerAccessResponse
	if err := githubAppBoundedJSONRequest(
		ctx, client, http.MethodPost, &tokenURL, jwt, body,
		http.StatusCreated, &access,
	); err != nil {
		return 0, "", err
	}
	if access.Token == "" {
		return 0, "", errors.New("GitHub App metadata token response was invalid")
	}
	defer func() { access.Token = "" }()
	repositoryURL := *source
	repositoryURL.Path = fmt.Sprintf("/repositories/%d", repositoryID)
	repositoryURL.RawPath = ""
	var repository struct {
		ID       int64  `json:"id"`
		FullName string `json:"full_name"`
	}
	if err := githubAppBoundedJSONRequest(
		ctx, client, http.MethodGet, &repositoryURL, access.Token, nil,
		http.StatusOK, &repository,
	); err != nil {
		return 0, "", err
	}
	segments := strings.Split(repository.FullName, "/")
	if repository.ID != repositoryID || len(segments) != 2 ||
		!validGitHubPathSegment(segments[0]) ||
		!validGitHubPathSegment(segments[1]) {
		return 0, "", errors.New("GitHub App canonical repository identity did not match its redirect")
	}
	canonicalURL := "https://github.com/" + url.PathEscape(segments[0]) +
		"/" + url.PathEscape(segments[1])
	if _, _, err := githubAppInstallationEndpoint(canonicalURL); err != nil {
		return 0, "", errors.New("GitHub App canonical repository URL was invalid")
	}
	return installation.ID, canonicalURL, nil
}
