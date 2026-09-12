package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

const (
	githubRunnerAccessResponseLimit  = 4096
	githubRunnerAccessDefaultTimeout = 15 * time.Second
)

var (
	errGitHubRunnerAuthorization      = errors.New("runner credential authorization failed")
	errGitHubRunnerCredentialRejected = fmt.Errorf("%w: credential was rejected", errGitHubRunnerAuthorization)
	errGitHubRunnerPermissionDenied   = fmt.Errorf("%w: permission was denied", errGitHubRunnerAuthorization)
	errGitHubRunnerOrganizationAccess = fmt.Errorf("%w: organization authorization is required", errGitHubRunnerAuthorization)
	errGitHubRunnerNotFound           = errors.New("runner registration target was not found")
	errGitHubRunnerRateLimited        = errors.New("runner credential check was rate limited")
	errGitHubRunnerResponse           = errors.New("runner credential check returned an invalid response")
)

type githubRunnerAccessResponse struct {
	Token string `json:"token"`
}

func githubRunnerRegistrationAccessEndpoint(registrationURL string) (string, error) {
	parsed, err := url.Parse(registrationURL)
	if err != nil {
		return "", fmt.Errorf("parse runner registration URL: %w", err)
	}
	if parsed.Scheme != "https" ||
		!strings.EqualFold(parsed.Host, "github.com") ||
		parsed.User != nil ||
		parsed.RawQuery != "" ||
		parsed.Fragment != "" {
		return "", fmt.Errorf("runner registration URL must be an HTTPS github.com URL")
	}

	segments := strings.Split(strings.Trim(parsed.EscapedPath(), "/"), "/")
	for index, segment := range segments {
		decoded, decodeErr := url.PathUnescape(segment)
		if decodeErr != nil || decoded == "" || decoded == "." || decoded == ".." ||
			strings.ContainsAny(decoded, `/\`) {
			return "", fmt.Errorf("runner registration URL contains an invalid path segment")
		}
		segments[index] = url.PathEscape(decoded)
	}

	switch {
	case len(segments) == 1:
		return "/orgs/" + segments[0] + "/actions/runners/registration-token", nil
	case len(segments) == 2 && segments[0] == "enterprises":
		return "/enterprises/" + segments[1] + "/actions/runners/registration-token", nil
	case len(segments) == 2:
		return "/repos/" + segments[0] + "/" + segments[1] +
			"/actions/runners/registration-token", nil
	default:
		return "", fmt.Errorf("runner registration URL has an unsupported path")
	}
}

func checkGitHubRunnerRegistrationAccess(
	ctx context.Context,
	client *http.Client,
	apiBaseURL string,
	endpoint string,
	accessToken string,
) error {
	if client == nil {
		return fmt.Errorf("%w: HTTP client is unavailable", errGitHubRunnerResponse)
	}
	if strings.TrimSpace(accessToken) == "" {
		return fmt.Errorf("%w: access token is empty", errGitHubRunnerAuthorization)
	}
	if err := validateGitHubRunnerRegistrationAccessEndpoint(endpoint); err != nil {
		return err
	}

	base, err := url.Parse(apiBaseURL)
	if err != nil ||
		base.Scheme != "https" ||
		base.Host == "" ||
		base.User != nil ||
		base.RawQuery != "" ||
		base.Fragment != "" ||
		(base.Path != "" && base.Path != "/") {
		return fmt.Errorf("%w: API base URL is invalid", errGitHubRunnerResponse)
	}
	requestURL := *base
	requestURL.Path = endpoint
	requestURL.RawPath = ""

	request, err := http.NewRequestWithContext(ctx, http.MethodPost, requestURL.String(), nil)
	if err != nil {
		return fmt.Errorf("%w: create request", errGitHubRunnerResponse)
	}
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("Authorization", "Bearer "+accessToken)
	request.Header.Set("User-Agent", "pitcrew-manager")
	request.Header.Set("X-GitHub-Api-Version", "2022-11-28")

	response, err := client.Do(request)
	if err != nil {
		return fmt.Errorf("check runner credential authorization: %w", err)
	}
	defer response.Body.Close()

	switch response.StatusCode {
	case http.StatusCreated:
		body, readErr := io.ReadAll(io.LimitReader(
			response.Body,
			githubRunnerAccessResponseLimit+1,
		))
		defer clear(body)
		if readErr != nil || len(body) > githubRunnerAccessResponseLimit {
			return fmt.Errorf("%w: response body could not be read", errGitHubRunnerResponse)
		}
		var accessResponse githubRunnerAccessResponse
		if json.Unmarshal(body, &accessResponse) != nil ||
			strings.TrimSpace(accessResponse.Token) == "" {
			return fmt.Errorf("%w: response body was malformed", errGitHubRunnerResponse)
		}
		accessResponse.Token = ""
		return nil
	case http.StatusUnauthorized:
		return errGitHubRunnerCredentialRejected
	case http.StatusForbidden:
		if response.Header.Get("Retry-After") != "" ||
			response.Header.Get("X-RateLimit-Remaining") == "0" {
			return errGitHubRunnerRateLimited
		}
		if strings.Contains(
			strings.ToLower(response.Header.Get("X-GitHub-SSO")),
			"required",
		) {
			return errGitHubRunnerOrganizationAccess
		}
		return errGitHubRunnerPermissionDenied
	case http.StatusNotFound:
		return errGitHubRunnerNotFound
	case http.StatusTooManyRequests:
		return errGitHubRunnerRateLimited
	default:
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, githubRunnerAccessResponseLimit))
		return fmt.Errorf("%w: HTTP status %d", errGitHubRunnerResponse, response.StatusCode)
	}
}

func validateGitHubRunnerRegistrationAccessEndpoint(endpoint string) error {
	parsed, err := url.Parse(endpoint)
	if err != nil ||
		parsed.IsAbs() ||
		parsed.Host != "" ||
		parsed.User != nil ||
		parsed.RawQuery != "" ||
		parsed.Fragment != "" ||
		parsed.RawPath != "" {
		return fmt.Errorf("%w: registration endpoint is invalid", errGitHubRunnerResponse)
	}

	segments := strings.Split(strings.Trim(parsed.Path, "/"), "/")
	valid := false
	switch {
	case len(segments) == 6 &&
		segments[0] == "repos" &&
		segments[3] == "actions" &&
		segments[4] == "runners" &&
		segments[5] == "registration-token":
		valid = true
	case len(segments) == 5 &&
		(segments[0] == "orgs" || segments[0] == "enterprises") &&
		segments[2] == "actions" &&
		segments[3] == "runners" &&
		segments[4] == "registration-token":
		valid = true
	}
	if !valid {
		return fmt.Errorf("%w: registration endpoint is unsupported", errGitHubRunnerResponse)
	}
	for _, segment := range segments {
		if segment == "" || segment == "." || segment == ".." ||
			strings.ContainsAny(segment, `\`) {
			return fmt.Errorf("%w: registration endpoint contains an invalid path segment", errGitHubRunnerResponse)
		}
	}
	return nil
}

func runGitHubRunnerAccessCheck(args []string) error {
	flags := flag.NewFlagSet("check-github-runner-access", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	endpoint := flags.String("endpoint", "", "validated GitHub runner registration-token endpoint")
	timeoutSeconds := flags.Int("timeout-seconds", int(githubRunnerAccessDefaultTimeout/time.Second), "request timeout")
	if err := flags.Parse(args); err != nil {
		return fmt.Errorf("%w: parse arguments", errGitHubRunnerResponse)
	}
	if flags.NArg() != 0 || *timeoutSeconds <= 0 || time.Duration(*timeoutSeconds)*time.Second > time.Minute {
		return fmt.Errorf("%w: arguments are invalid", errGitHubRunnerResponse)
	}

	client := &http.Client{
		Timeout: time.Duration(*timeoutSeconds) * time.Second,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	ctx, cancel := context.WithTimeout(
		context.Background(),
		time.Duration(*timeoutSeconds)*time.Second,
	)
	defer cancel()
	return checkGitHubRunnerRegistrationAccess(
		ctx,
		client,
		githubAPIBaseURL,
		*endpoint,
		os.Getenv("ACCESS_TOKEN"),
	)
}

func githubRunnerAccessExitCode(err error) int {
	switch {
	case err == nil:
		return 0
	case errors.Is(err, errGitHubRunnerCredentialRejected):
		return 3
	case errors.Is(err, errGitHubRunnerNotFound):
		return 4
	case errors.Is(err, errGitHubRunnerRateLimited):
		return 5
	case errors.Is(err, context.DeadlineExceeded):
		return 6
	case errors.Is(err, errGitHubRunnerPermissionDenied):
		return 7
	case errors.Is(err, errGitHubRunnerOrganizationAccess):
		return 8
	case errors.Is(err, errGitHubRunnerAuthorization):
		return 3
	default:
		return 1
	}
}

func githubRunnerRegistrationAccessFailureEvidence(err error) string {
	switch {
	case errors.Is(err, errGitHubRunnerOrganizationAccess):
		return "stored runner credential requires organization authorization"
	case errors.Is(err, errGitHubRunnerPermissionDenied):
		return "stored runner credential lacks runner administration permission"
	case errors.Is(err, errGitHubRunnerCredentialRejected):
		return "stored runner credential was rejected"
	case errors.Is(err, errGitHubRunnerNotFound):
		return "runner registration target was not found or is excluded from credential access"
	case errors.Is(err, errGitHubRunnerRateLimited):
		return "runner credential authorization check was rate limited"
	case errors.Is(err, context.DeadlineExceeded):
		return "runner credential authorization check timed out"
	default:
		return "stored runner credential authorization check failed"
	}
}
