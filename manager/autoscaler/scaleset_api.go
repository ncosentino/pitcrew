package main

import (
	"context"
	"errors"
	"fmt"

	"github.com/actions/scaleset"
	"github.com/actions/scaleset/listener"
)

type scaleSetHandle struct {
	id   int
	name string
}

type jitRunnerConfig struct {
	runnerID   int64
	runnerName string
	encoded    string
}

type messageSession interface {
	listener.Client
	Close(ctx context.Context) error
}

type scaleSetService interface {
	ensureScaleSet(
		ctx context.Context,
		name string,
		runnerGroup string,
		labels []string,
	) (scaleSetHandle, error)
	findScaleSet(
		ctx context.Context,
		name string,
		runnerGroup string,
	) (scaleSetHandle, bool, error)
	generateJIT(
		ctx context.Context,
		scaleSetID int,
		runnerName string,
	) (jitRunnerConfig, error)
	removeRunner(ctx context.Context, runnerID int64) error
	openSession(
		ctx context.Context,
		scaleSetID int,
		owner string,
	) (messageSession, error)
	deleteScaleSet(ctx context.Context, scaleSetID int) error
}

type scaleSetServiceFactory interface {
	newService(registrationURL string) (scaleSetService, error)
}

type githubScaleSetServiceFactory struct {
	accessToken string
}

func (f githubScaleSetServiceFactory) newService(
	registrationURL string,
) (scaleSetService, error) {
	client, err := scaleset.NewClientWithPersonalAccessToken(
		scaleset.NewClientWithPersonalAccessTokenConfig{
			GitHubConfigURL:     registrationURL,
			PersonalAccessToken: f.accessToken,
			SystemInfo: scaleset.SystemInfo{
				System:    "pitcrew",
				Version:   "1",
				CommitSHA: "unknown",
				Subsystem: "autoscaler",
			},
		},
	)
	if err != nil {
		return nil, fmt.Errorf("create scale-set client for %s: %w", registrationURL, err)
	}
	return &githubScaleSetService{client: client}, nil
}

type githubScaleSetService struct {
	client *scaleset.Client
}

func (s *githubScaleSetService) ensureScaleSet(
	ctx context.Context,
	name string,
	runnerGroup string,
	labels []string,
) (scaleSetHandle, error) {
	runnerGroupID, err := s.runnerGroupID(ctx, runnerGroup)
	if err != nil {
		return scaleSetHandle{}, err
	}

	scaleSetLabels := make([]scaleset.Label, 0, len(labels))
	for _, label := range labels {
		scaleSetLabels = append(scaleSetLabels, scaleset.Label{Name: label})
	}
	desired := &scaleset.RunnerScaleSet{
		Name:          name,
		RunnerGroupID: runnerGroupID,
		Labels:        scaleSetLabels,
		RunnerSetting: scaleset.RunnerSetting{DisableUpdate: true},
	}
	existing, err := s.client.GetRunnerScaleSet(ctx, runnerGroupID, name)
	if err != nil {
		return scaleSetHandle{}, fmt.Errorf("find runner scale set %q: %w", name, err)
	}

	var result *scaleset.RunnerScaleSet
	if existing == nil {
		result, err = s.client.CreateRunnerScaleSet(ctx, desired)
		if err != nil {
			return scaleSetHandle{}, fmt.Errorf("create runner scale set %q: %w", name, err)
		}
	} else {
		result, err = s.client.UpdateRunnerScaleSet(ctx, existing.ID, desired)
		if err != nil {
			return scaleSetHandle{}, fmt.Errorf("update runner scale set %q: %w", name, err)
		}
	}
	if result == nil || result.ID == 0 {
		return scaleSetHandle{}, fmt.Errorf("runner scale set %q returned no ID", name)
	}
	s.client.SetSystemInfo(scaleset.SystemInfo{
		System:     "pitcrew",
		Version:    "1",
		CommitSHA:  "unknown",
		Subsystem:  "autoscaler",
		ScaleSetID: result.ID,
	})
	return scaleSetHandle{id: result.ID, name: result.Name}, nil
}

func (s *githubScaleSetService) findScaleSet(
	ctx context.Context,
	name string,
	runnerGroup string,
) (scaleSetHandle, bool, error) {
	runnerGroupID, err := s.runnerGroupID(ctx, runnerGroup)
	if err != nil {
		return scaleSetHandle{}, false, err
	}
	existing, err := s.client.GetRunnerScaleSet(ctx, runnerGroupID, name)
	if err != nil {
		return scaleSetHandle{}, false, fmt.Errorf(
			"find runner scale set %q: %w",
			name,
			err,
		)
	}
	if existing == nil {
		return scaleSetHandle{}, false, nil
	}
	return scaleSetHandle{id: existing.ID, name: existing.Name}, true, nil
}

func (s *githubScaleSetService) runnerGroupID(
	ctx context.Context,
	runnerGroup string,
) (int, error) {
	if runnerGroup == scaleset.DefaultRunnerGroup {
		return 1, nil
	}
	group, err := s.client.GetRunnerGroupByName(ctx, runnerGroup)
	if err != nil {
		return 0, fmt.Errorf("resolve runner group %q: %w", runnerGroup, err)
	}
	return group.ID, nil
}

func (s *githubScaleSetService) generateJIT(
	ctx context.Context,
	scaleSetID int,
	runnerName string,
) (jitRunnerConfig, error) {
	jit, err := s.client.GenerateJitRunnerConfig(
		ctx,
		&scaleset.RunnerScaleSetJitRunnerSetting{
			Name:       runnerName,
			WorkFolder: "_work",
		},
		scaleSetID,
	)
	if err != nil {
		return jitRunnerConfig{}, fmt.Errorf("generate JIT runner configuration: %w", err)
	}
	if jit == nil || jit.Runner == nil || jit.Runner.ID == 0 ||
		jit.Runner.Name == "" || jit.EncodedJITConfig == "" {
		return jitRunnerConfig{}, errors.New("scale-set API returned an incomplete JIT runner configuration")
	}
	return jitRunnerConfig{
		runnerID:   int64(jit.Runner.ID),
		runnerName: jit.Runner.Name,
		encoded:    jit.EncodedJITConfig,
	}, nil
}

func (s *githubScaleSetService) removeRunner(
	ctx context.Context,
	runnerID int64,
) error {
	return s.client.RemoveRunner(ctx, runnerID)
}

func (s *githubScaleSetService) openSession(
	ctx context.Context,
	scaleSetID int,
	owner string,
) (messageSession, error) {
	session, err := s.client.MessageSessionClient(ctx, scaleSetID, owner)
	if err != nil {
		return nil, fmt.Errorf("open scale-set message session: %w", err)
	}
	return session, nil
}

func (s *githubScaleSetService) deleteScaleSet(
	ctx context.Context,
	scaleSetID int,
) error {
	return s.client.DeleteRunnerScaleSet(ctx, scaleSetID)
}
