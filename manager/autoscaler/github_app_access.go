package main

import (
	"context"
	"errors"
	"flag"
	"io"
	"os"

	"github.com/actions/scaleset"
)

type registrationURLList []string

func (l *registrationURLList) String() string {
	return ""
}

func (l *registrationURLList) Set(value string) error {
	if value == "" {
		return errors.New("registration URL cannot be empty")
	}
	*l = append(*l, value)
	return nil
}

func runGitHubAppAccessCheck(args []string) error {
	flags := flag.NewFlagSet("check-github-app-access", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	var registrationURLs registrationURLList
	flags.Var(
		&registrationURLs,
		"registration-url",
		"repository or organization registration URL",
	)
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 || len(registrationURLs) == 0 {
		return errors.New("at least one registration URL is required")
	}
	app, err := loadGitHubAppCredentials(
		os.Getenv("PITCREW_GITHUB_APP_CLIENT_ID"),
		os.Getenv("PITCREW_GITHUB_APP_PRIVATE_KEY_PATH"),
		realClock{},
	)
	if err != nil {
		return err
	}
	factory := githubScaleSetServiceFactory{
		githubApp: app,
	}
	for _, registrationURL := range registrationURLs {
		service, createErr := factory.newService(registrationURL)
		if createErr != nil {
			return createErr
		}
		ctx, cancel := context.WithTimeout(
			context.Background(),
			githubAppRequestTimeout,
		)
		_, _, findErr := service.findScaleSet(
			ctx,
			"pitcrew-authentication-check",
			scaleset.DefaultRunnerGroup,
		)
		cancel()
		if findErr != nil {
			return findErr
		}
	}
	return nil
}
