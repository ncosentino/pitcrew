package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"math/big"
	"net"
	"net/url"
	"strconv"
	"strings"
	"unicode"
)

type desiredClassification string

const (
	classificationInvalid   desiredClassification = "invalid"
	classificationStale     desiredClassification = "stale"
	classificationUnchanged desiredClassification = "unchanged"
	classificationConflict  desiredClassification = "conflict"
	classificationNew       desiredClassification = "new"
)

type desiredRepository struct {
	URL     string `json:"url"`
	Workers int    `json:"workers"`
}

type desiredState struct {
	SchemaVersion int                 `json:"schemaVersion"`
	Generation    int                 `json:"generation"`
	Scope         string              `json:"scope"`
	Repositories  []desiredRepository `json:"repositories"`
	Replicas      *int                `json:"replicas"`
}

type parsedDesiredState struct {
	state     desiredState
	stateHash string
	raw       []byte
}

func parseDesiredState(data []byte, expectedScope string) (parsedDesiredState, error) {
	var rawDocument any
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err := decoder.Decode(&rawDocument); err != nil {
		return parsedDesiredState{}, fmt.Errorf("decode desired-capacity document: %w", err)
	}
	if err := requireJSONEOF(decoder); err != nil {
		return parsedDesiredState{}, err
	}
	if _, ok := rawDocument.(map[string]any); !ok {
		return parsedDesiredState{}, errors.New("desired-capacity document must be a JSON object")
	}

	rawObject := rawDocument.(map[string]any)
	state, err := desiredStateFromJSON(rawObject)
	if err != nil {
		return parsedDesiredState{}, err
	}
	if err := canonicalizeDesiredRepositoryURLs(&state, rawObject); err != nil {
		return parsedDesiredState{}, err
	}
	if err := validateDesiredState(state, expectedScope); err != nil {
		return parsedDesiredState{}, err
	}

	normalized, err := normalizeJSONValue(rawDocument)
	if err != nil {
		return parsedDesiredState{}, fmt.Errorf("normalize desired-capacity document: %w", err)
	}
	var canonicalBuffer bytes.Buffer
	canonicalEncoder := json.NewEncoder(&canonicalBuffer)
	canonicalEncoder.SetEscapeHTML(false)
	if err := canonicalEncoder.Encode(normalized); err != nil {
		return parsedDesiredState{}, fmt.Errorf("canonicalize desired-capacity document: %w", err)
	}
	canonical := bytes.TrimSuffix(canonicalBuffer.Bytes(), []byte{'\n'})
	if len(canonical) == 0 {
		return parsedDesiredState{}, errors.New("canonical desired-capacity document is empty")
	}
	stateDigest := sha256.Sum256(canonical)
	return parsedDesiredState{
		state:     state,
		stateHash: hex.EncodeToString(stateDigest[:]),
		raw:       append([]byte(nil), data...),
	}, nil
}

func desiredStateFromJSON(raw map[string]any) (desiredState, error) {
	schemaVersion, err := jsonInteger(raw["schemaVersion"], "schemaVersion")
	if err != nil {
		return desiredState{}, err
	}
	generation, err := jsonInteger(raw["generation"], "generation")
	if err != nil {
		return desiredState{}, err
	}
	scope, ok := raw["scope"].(string)
	if !ok {
		return desiredState{}, errors.New("desired-capacity scope must be a string")
	}
	rawRepositories, ok := raw["repositories"].([]any)
	if !ok {
		return desiredState{}, errors.New("desired-capacity repositories must be an array")
	}
	repositories := make([]desiredRepository, 0, len(rawRepositories))
	for index, rawRepository := range rawRepositories {
		repositoryObject, ok := rawRepository.(map[string]any)
		if !ok {
			return desiredState{}, fmt.Errorf("desired-capacity repository at index %d must be an object", index)
		}
		repositoryURL, ok := repositoryObject["url"].(string)
		if !ok {
			return desiredState{}, fmt.Errorf("desired-capacity repository at index %d requires a string URL", index)
		}
		workers, err := jsonInteger(
			repositoryObject["workers"],
			fmt.Sprintf("repositories[%d].workers", index),
		)
		if err != nil {
			return desiredState{}, err
		}
		repositories = append(repositories, desiredRepository{
			URL:     repositoryURL,
			Workers: workers,
		})
	}

	var replicas *int
	if rawReplicas, exists := raw["replicas"]; exists && rawReplicas != nil {
		value, err := jsonInteger(rawReplicas, "replicas")
		if err != nil {
			return desiredState{}, err
		}
		replicas = &value
	}
	return desiredState{
		SchemaVersion: schemaVersion,
		Generation:    generation,
		Scope:         scope,
		Repositories:  repositories,
		Replicas:      replicas,
	}, nil
}

func jsonInteger(value any, field string) (int, error) {
	number, ok := value.(json.Number)
	if !ok {
		return 0, fmt.Errorf("desired-capacity %s must be an integer", field)
	}
	rational, ok := new(big.Rat).SetString(string(number))
	if !ok || !rational.IsInt() || !rational.Num().IsInt64() {
		return 0, fmt.Errorf("desired-capacity %s must be an integer", field)
	}
	integer := rational.Num().Int64()
	if strconv.IntSize == 32 && (integer < math.MinInt32 || integer > math.MaxInt32) {
		return 0, fmt.Errorf("desired-capacity %s must be an integer", field)
	}
	return int(integer), nil
}

func requireJSONEOF(decoder *json.Decoder) error {
	var trailing any
	err := decoder.Decode(&trailing)
	if errors.Is(err, io.EOF) {
		return nil
	}
	if err == nil {
		return errors.New("desired-capacity document contains multiple JSON values")
	}
	return fmt.Errorf("decode trailing desired-capacity content: %w", err)
}

func validateDesiredState(state desiredState, expectedScope string) error {
	if state.SchemaVersion != 1 {
		return fmt.Errorf("desired-capacity schemaVersion must be 1, got %d", state.SchemaVersion)
	}
	if state.Generation < 1 {
		return errors.New("desired-capacity generation must be a positive integer")
	}
	if expectedScope != "" && state.Scope != expectedScope {
		return fmt.Errorf(
			"desired-capacity scope %q conflicts with configured scope %q",
			state.Scope,
			expectedScope,
		)
	}

	switch state.Scope {
	case "repo":
		if len(state.Repositories) == 0 {
			return errors.New("repository scope requires at least one repository target")
		}
		if state.Replicas != nil {
			return errors.New("repository scope cannot define replicas")
		}
		seen := make(map[string]struct{}, len(state.Repositories))
		for _, repository := range state.Repositories {
			canonicalURL, err := canonicalRepositoryURL(repository.URL)
			if err != nil {
				return err
			}
			if repository.Workers < 1 {
				return fmt.Errorf(
					"repository %q must request at least one worker",
					repository.URL,
				)
			}
			if _, exists := seen[canonicalURL]; exists {
				return fmt.Errorf(
					"desired-capacity contains duplicate repository URL %q",
					canonicalURL,
				)
			}
			seen[canonicalURL] = struct{}{}
		}
	case "org", "ent":
		if len(state.Repositories) != 0 {
			return errors.New("organization and enterprise scope cannot define repository targets")
		}
		if state.Replicas == nil || *state.Replicas < 1 {
			return errors.New("organization and enterprise scope requires positive replicas")
		}
	default:
		return fmt.Errorf("desired-capacity scope must be repo, org, or ent, got %q", state.Scope)
	}
	return nil
}

func canonicalizeDesiredRepositoryURLs(
	state *desiredState,
	rawObject map[string]any,
) error {
	if state == nil || state.Scope != "repo" {
		return nil
	}
	var rawRepositories []any
	if rawObject != nil {
		rawRepositories, _ = rawObject["repositories"].([]any)
	}
	for index := range state.Repositories {
		canonicalURL, err := canonicalRepositoryURL(state.Repositories[index].URL)
		if err != nil {
			return err
		}
		state.Repositories[index].URL = canonicalURL
		if index < len(rawRepositories) {
			if repositoryObject, ok := rawRepositories[index].(map[string]any); ok {
				repositoryObject["url"] = canonicalURL
			}
		}
	}
	return nil
}

func canonicalRepositoryURL(value string) (string, error) {
	if value == "" || value == "-" || value != strings.TrimSpace(value) ||
		strings.IndexFunc(value, unicode.IsSpace) >= 0 {
		return "", fmt.Errorf("repository URL %q is not canonical", value)
	}
	parsed, err := url.Parse(value)
	if err != nil {
		return "", fmt.Errorf("repository URL %q is invalid: %w", value, err)
	}
	scheme := strings.ToLower(parsed.Scheme)
	if (scheme != "http" && scheme != "https") ||
		parsed.Host == "" ||
		strings.Trim(parsed.Path, "/") == "" ||
		parsed.User != nil ||
		parsed.RawQuery != "" ||
		parsed.Fragment != "" {
		return "", fmt.Errorf(
			"repository URL %q must be an absolute HTTP(S) URL without credentials, query, or fragment",
			value,
		)
	}
	path := strings.TrimRight(parsed.Path, "/")
	if strings.HasSuffix(strings.ToLower(path), ".git") {
		path = path[:len(path)-4]
	}
	if strings.Trim(path, "/") == "" {
		return "", fmt.Errorf("repository URL %q does not identify a repository", value)
	}

	hostname := strings.ToLower(parsed.Hostname())
	port := parsed.Port()
	if (scheme == "http" && port == "80") ||
		(scheme == "https" && port == "443") {
		port = ""
	}
	if port != "" {
		parsed.Host = net.JoinHostPort(hostname, port)
	} else if strings.Contains(hostname, ":") {
		parsed.Host = "[" + hostname + "]"
	} else {
		parsed.Host = hostname
	}
	parsed.Scheme = scheme
	parsed.Path = path
	parsed.RawPath = ""
	parsed.ForceQuery = false
	return strings.TrimRight(parsed.String(), "/"), nil
}

func classifyDesiredState(
	data []byte,
	expectedScope string,
	currentGeneration int,
	currentHash string,
) (desiredClassification, parsedDesiredState, error) {
	parsed, err := parseDesiredState(data, expectedScope)
	if err != nil {
		return classificationInvalid, parsedDesiredState{}, err
	}
	switch {
	case parsed.state.Generation < currentGeneration:
		return classificationStale, parsed, nil
	case parsed.state.Generation == currentGeneration && parsed.stateHash == currentHash:
		return classificationUnchanged, parsed, nil
	case parsed.state.Generation == currentGeneration:
		return classificationConflict, parsed, nil
	default:
		return classificationNew, parsed, nil
	}
}

func normalizeJSONValue(value any) (any, error) {
	switch typed := value.(type) {
	case map[string]any:
		normalized := make(map[string]any, len(typed))
		for key, child := range typed {
			value, err := normalizeJSONValue(child)
			if err != nil {
				return nil, err
			}
			normalized[key] = value
		}
		return normalized, nil
	case []any:
		normalized := make([]any, len(typed))
		for index, child := range typed {
			value, err := normalizeJSONValue(child)
			if err != nil {
				return nil, err
			}
			normalized[index] = value
		}
		return normalized, nil
	case json.Number:
		if integer, err := strconv.ParseInt(string(typed), 10, 64); err == nil {
			return integer, nil
		}
		if rational, ok := new(big.Rat).SetString(string(typed)); ok && rational.IsInt() {
			if rational.Num().IsInt64() {
				return rational.Num().Int64(), nil
			}
			return json.Number(rational.Num().String()), nil
		}
		floating, err := strconv.ParseFloat(string(typed), 64)
		if err != nil || math.IsInf(floating, 0) || math.IsNaN(floating) {
			return nil, fmt.Errorf("invalid JSON number %q", typed)
		}
		if floating == math.Trunc(floating) &&
			floating >= math.MinInt64 &&
			floating <= math.MaxInt64 {
			return int64(floating), nil
		}
		return floating, nil
	default:
		return value, nil
	}
}
