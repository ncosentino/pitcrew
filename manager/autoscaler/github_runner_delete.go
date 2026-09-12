package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const githubAPIBaseURL = "https://api.github.com"

var runnerEndpointPattern = regexp.MustCompile(
	`^/(repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+|orgs/[A-Za-z0-9_.-]+|enterprises/[A-Za-z0-9_.-]+)/actions/runners$`,
)

func runGitHubRunnerDelete(args []string) error {
	flags := flag.NewFlagSet("delete-github-runner", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	endpoint := flags.String("endpoint", "", "validated GitHub Actions runner endpoint")
	runnerID := flags.Int64("runner-id", 0, "exact GitHub runner registration ID")
	timeoutSeconds := flags.Int("timeout-seconds", 5, "request timeout in seconds")
	if err := flags.Parse(args); err != nil {
		return errors.New("invalid arguments")
	}
	if flags.NArg() != 0 {
		return errors.New("unexpected positional arguments")
	}
	token := os.Getenv("ACCESS_TOKEN")
	if token == "" {
		return errors.New("ACCESS_TOKEN is required")
	}
	if *timeoutSeconds < 1 || *timeoutSeconds > 60 {
		return errors.New("timeout-seconds must be between 1 and 60")
	}
	client := &http.Client{
		Timeout: time.Duration(*timeoutSeconds) * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	ctx, cancel := context.WithTimeout(
		context.Background(),
		time.Duration(*timeoutSeconds)*time.Second,
	)
	defer cancel()
	return deleteGitHubRunner(ctx, client, githubAPIBaseURL, *endpoint, *runnerID, token)
}

func deleteGitHubRunner(
	ctx context.Context,
	client *http.Client,
	baseURL string,
	endpoint string,
	runnerID int64,
	token string,
) error {
	if !runnerEndpointPattern.MatchString(endpoint) {
		return errors.New("runner endpoint is invalid")
	}
	for _, segment := range strings.Split(endpoint, "/") {
		if segment == "." || segment == ".." {
			return errors.New("runner endpoint is invalid")
		}
	}
	if runnerID < 1 {
		return errors.New("runner ID must be positive")
	}
	if token == "" {
		return errors.New("access token is required")
	}
	request, err := http.NewRequestWithContext(
		ctx,
		http.MethodDelete,
		baseURL+endpoint+"/"+strconv.FormatInt(runnerID, 10),
		nil,
	)
	if err != nil {
		return errors.New("create runner deletion request")
	}
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	request.Header.Set("User-Agent", "pitcrew-manager")
	response, err := client.Do(request)
	if err != nil {
		return errors.New("runner deletion request failed")
	}
	defer response.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 1024))
	if response.StatusCode == http.StatusNoContent ||
		response.StatusCode == http.StatusNotFound {
		return nil
	}
	return fmt.Errorf("runner deletion returned HTTP %d", response.StatusCode)
}
