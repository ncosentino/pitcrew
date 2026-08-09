module github.com/ncosentino/pitcrew/manager/autoscaler

go 1.25.3

require (
	github.com/actions/scaleset v0.4.0
	github.com/google/uuid v1.6.0
	github.com/ncosentino/pitcrew/manager/admission v0.0.0
)

require (
	github.com/golang-jwt/jwt/v4 v4.5.2 // indirect
	github.com/hashicorp/go-cleanhttp v0.5.2 // indirect
	github.com/hashicorp/go-retryablehttp v0.7.8 // indirect
)

// The admission wire client lives in the sibling manager/admission module so
// the shell-manager CLI and the Go autoscaler share one protocol
// implementation (see ADR-0003). Both modules are built from the same
// manager/ Docker build context, so this path stays valid there too.
replace github.com/ncosentino/pitcrew/manager/admission => ../admission
