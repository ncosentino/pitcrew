#!/bin/sh

observed_state_is_valid() {
    jq -e '
        def nonnegative_integer:
            type == "number" and . >= 0 and floor == .;
        def optional_counter:
            . == null or nonnegative_integer;
        def valid_resource_usage:
            type == "object"
            and (.cpuCores | type == "number" and . >= 0)
            and (.memoryWorkingSetBytes | nonnegative_integer)
            and (.pids | nonnegative_integer)
            and (.networkRxBytes | optional_counter)
            and (.networkTxBytes | optional_counter)
            and (.blockReadBytes | optional_counter)
            and (.blockWriteBytes | optional_counter);
        def valid_io_counters:
            has("networkRxBytes")
            and has("networkTxBytes")
            and has("blockReadBytes")
            and has("blockWriteBytes");
        def valid_resource_policy:
            type == "object"
            and has("memoryBytes")
            and has("memorySwapBytes")
            and has("cpuCores")
            and has("pids")
            and (.memoryBytes == null or (.memoryBytes | nonnegative_integer and . >= 6291456))
            and (
                .memorySwapBytes == null
                or (
                    (.memorySwapBytes | nonnegative_integer and . >= 6291456)
                    and .memoryBytes != null
                    and .memorySwapBytes >= .memoryBytes
                )
            )
            and (
                .cpuCores == null
                or (
                    .cpuCores
                    | type == "string"
                    and test("^(?:[1-9][0-9]*(?:\\.[0-9]{1,9})?|0\\.[0-9]{0,8}[1-9])$")
                )
            )
            and (
                .pids == null
                or (.pids | nonnegative_integer and . >= 1 and . <= 2147483647)
            )
            and (
                [.memoryBytes, .memorySwapBytes, .cpuCores, .pids]
                | map(select(. != null))
                | length > 0
            );
        def valid_last_exit:
            type == "object"
            and (.observedAt | type == "string" and length > 0)
            and (
                .classification == "clean"
                or .classification == "oom-killed"
                or .classification == "sigkill"
                or .classification == "signal"
                or .classification == "error"
                or .classification == "launch-failure"
                or .classification == "unknown"
            )
            and (
                .exitCode == null
                or (.exitCode | nonnegative_integer and . <= 255)
            )
            and (
                .signal == null
                or (.signal | nonnegative_integer and . >= 1 and . <= 64)
            )
            and (.dockerOomKilled == null or (.dockerOomKilled | type == "boolean"))
            and (
                .evidence == "docker-inspect"
                or .evidence == "docker-wait"
                or .evidence == "launch"
                or .evidence == "unavailable"
            );
        def valid_host_capacity:
            type == "object"
            and (.logicalProcessorCount | nonnegative_integer and . > 0)
            and (.memoryBytes | nonnegative_integer and . > 0);
        def valid_nullable_hardware_text($maximum):
            . == null
            or (
                type == "string"
                and length >= 1
                and length <= $maximum
                and (explode | all(. >= 32 and . != 127))
            );
        def valid_nullable_positive_integer:
            . == null or (nonnegative_integer and . > 0);
        def valid_host_hardware:
            type == "object"
            and (
                .status == "current"
                or .status == "stale"
                or .status == "unavailable"
            )
            and (
                .collectedAt == null
                or (
                    (.collectedAt | type == "string")
                    and ((.collectedAt | fromdateiso8601?) | type == "number")
                )
            )
            and (
                (.attemptedAt | type == "string")
                and ((.attemptedAt | fromdateiso8601?) | type == "number")
            )
            and (
                .inventoryHash == null
                or (.inventoryHash | type == "string" and test("^[0-9a-f]{64}$"))
            )
            and (.processorModel | valid_nullable_hardware_text(256))
            and (.architecture | valid_nullable_hardware_text(64))
            and (.physicalCoreCount | valid_nullable_positive_integer)
            and (.logicalProcessorCount | valid_nullable_positive_integer)
            and (.performanceCoreCount | valid_nullable_positive_integer)
            and (.efficiencyCoreCount | valid_nullable_positive_integer)
            and (.memoryBytes | valid_nullable_positive_integer)
            and (.operatingSystem | valid_nullable_hardware_text(256))
            and (.kernelVersion | valid_nullable_hardware_text(256))
            and (.dockerServerVersion | valid_nullable_hardware_text(256))
            and (.dockerStorageDriver | valid_nullable_hardware_text(256))
            and (.dockerBackingFilesystem | valid_nullable_hardware_text(256))
            and (
                if .status == "unavailable" then
                    .collectedAt == null
                    and .inventoryHash == null
                    and .processorModel == null
                    and .architecture == null
                    and .physicalCoreCount == null
                    and .logicalProcessorCount == null
                    and .performanceCoreCount == null
                    and .efficiencyCoreCount == null
                    and .memoryBytes == null
                    and .operatingSystem == null
                    and .kernelVersion == null
                    and .dockerServerVersion == null
                    and .dockerStorageDriver == null
                    and .dockerBackingFilesystem == null
                else
                    .collectedAt != null
                    and .inventoryHash != null
                    and (
                        [
                            .processorModel,
                            .architecture,
                            .physicalCoreCount,
                            .logicalProcessorCount,
                            .performanceCoreCount,
                            .efficiencyCoreCount,
                            .memoryBytes,
                            .operatingSystem,
                            .kernelVersion,
                            .dockerServerVersion,
                            .dockerStorageDriver,
                            .dockerBackingFilesystem
                        ]
                        | map(select(. != null))
                        | length > 0
                    )
                end
            );
        def valid_host_admission_accounting:
            type == "object"
            and (.unitCost | nonnegative_integer and . > 0)
            and (.reservedUnits | nonnegative_integer)
            and (.borrowable | type == "boolean")
            and (
                .profilePolicyFingerprint == null
                or (
                    .profilePolicyFingerprint
                    | type == "string" and test("^[A-Za-z0-9_-]{1,128}$")
                )
            )
            and (.activeUnits | nonnegative_integer)
            and (.provisionalUnits | nonnegative_integer)
            and (.heldUnits | nonnegative_integer)
            and (.borrowedUnits | nonnegative_integer)
            and (
                (
                    .pendingUnits == null
                    and .withheldUnits == null
                )
                or (
                    (.pendingUnits | nonnegative_integer)
                    and (.withheldUnits | nonnegative_integer)
                    and .withheldUnits == .pendingUnits
                )
            )
            and (.heldUnits == (.activeUnits + .provisionalUnits))
            and (.borrowedUnits == ([.heldUnits - .reservedUnits, 0] | max));
        def valid_host_admission_decision:
            type == "object"
            and (.sequence | nonnegative_integer)
            and (
                .command == "acquire"
                or .command == "adopt"
                or .command == "renew"
                or .command == "activate"
                or .command == "release"
                or .command == "reconcile"
            )
            and (.granted | type == "boolean")
            and (
                .failureCategory == null
                or (
                    .failureCategory
                    | type == "string"
                    and length > 0
                    and length <= 64
                    and test("^[a-z][a-z0-9]*(-[a-z0-9]+)*$")
                )
            )
            and (.decidedAtUnixNano | nonnegative_integer);
        # valid_host_admission enforces the closed hostAdmission.status
        # vocabulary from ADR-0003: "disabled" and "unavailable" never carry
        # a measured value (null, never a fabricated zero), while
        # "available" and "degraded" always carry the host-wide budget
        # fields. namespace is required whenever host admission is
        # configured (every status except "disabled"), independent of
        # whether the coordinator was reachable.
        def valid_host_admission:
            type == "object"
            and (
                .status == "disabled"
                or .status == "available"
                or .status == "degraded"
                or .status == "unavailable"
            )
            and (
                .namespace == null
                or (.namespace | type == "string" and test("^[a-z][a-z0-9-]{0,31}$"))
            )
            and (.epoch == null or (.epoch | nonnegative_integer))
            and (.decisionSequence == null or (.decisionSequence | nonnegative_integer))
            and (.capacityUnits == null or (.capacityUnits | nonnegative_integer and . > 0))
            and (.safetyMarginUnits == null or (.safetyMarginUnits | nonnegative_integer))
            and (
                .effectiveTotalUnits == null
                or (.effectiveTotalUnits | nonnegative_integer and . > 0)
            )
            and (.availableUnits == null or (.availableUnits | nonnegative_integer))
            and (
                .hostPolicyFingerprint == null
                or (
                    .hostPolicyFingerprint
                    | type == "string" and test("^[A-Za-z0-9_-]{1,128}$")
                )
            )
            and (.accounting == null or (.accounting | valid_host_admission_accounting))
            and (.lastDecision == null or (.lastDecision | valid_host_admission_decision))
            and (
                if .status == "disabled" then
                    .namespace == null
                    and .epoch == null
                    and .decisionSequence == null
                    and .capacityUnits == null
                    and .safetyMarginUnits == null
                    and .effectiveTotalUnits == null
                    and .availableUnits == null
                    and .hostPolicyFingerprint == null
                    and .accounting == null
                    and .lastDecision == null
                elif .status == "unavailable" then
                    .namespace != null
                    and .epoch == null
                    and .decisionSequence == null
                    and .capacityUnits == null
                    and .safetyMarginUnits == null
                    and .effectiveTotalUnits == null
                    and .availableUnits == null
                    and .hostPolicyFingerprint == null
                    and .accounting == null
                    and .lastDecision == null
                elif .status == "available" then
                    .namespace != null
                    and .epoch != null
                    and .decisionSequence != null
                    and .capacityUnits != null
                    and .safetyMarginUnits != null
                    and .effectiveTotalUnits != null
                    and .availableUnits != null
                    and .hostPolicyFingerprint != null
                    and .accounting != null
                    and .accounting.profilePolicyFingerprint != null
                    and .accounting.pendingUnits != null
                    and .accounting.withheldUnits != null
                else
                    .namespace != null
                    and .epoch != null
                    and .decisionSequence != null
                    and .effectiveTotalUnits != null
                    and .availableUnits != null
                end
            );
        def optional_nonnegative_number:
            . == null or (type == "number" and . >= 0);
        def optional_percentage:
            . == null or (type == "number" and . >= 0 and . <= 100);
        def valid_host_pressure:
            type == "object"
            and (
                keys == [
                    "cpuPressureFullAvg10",
                    "cpuPressureSomeAvg10",
                    "cpuUtilizationPercent",
                    "ioPressureFullAvg10",
                    "ioPressureSomeAvg10",
                    "load1",
                    "load15",
                    "load5",
                    "memoryAvailableBytes",
                    "memoryPressureFullAvg10",
                    "memoryPressureSomeAvg10",
                    "memoryTotalBytes",
                    "source",
                    "status",
                    "swapUsedBytes"
                ]
            )
            and .source == "docker-host"
            and (
                .status == "available"
                or .status == "partial"
                or .status == "unavailable"
            )
            and (.cpuUtilizationPercent | optional_percentage)
            and (.load1 | optional_nonnegative_number)
            and (.load5 | optional_nonnegative_number)
            and (.load15 | optional_nonnegative_number)
            and (
                .memoryTotalBytes == null
                or (.memoryTotalBytes | nonnegative_integer and . > 0)
            )
            and (.memoryAvailableBytes | optional_counter)
            and (.swapUsedBytes | optional_counter)
            and (.cpuPressureSomeAvg10 | optional_percentage)
            and (.cpuPressureFullAvg10 | optional_percentage)
            and (.memoryPressureSomeAvg10 | optional_percentage)
            and (.memoryPressureFullAvg10 | optional_percentage)
            and (.ioPressureSomeAvg10 | optional_percentage)
            and (.ioPressureFullAvg10 | optional_percentage)
            and (
                .memoryTotalBytes == null
                or .memoryAvailableBytes == null
                or .memoryAvailableBytes <= .memoryTotalBytes
            )
            and (
                [
                    .cpuUtilizationPercent,
                    .load1,
                    .load5,
                    .load15,
                    .memoryTotalBytes,
                    .memoryAvailableBytes,
                    .swapUsedBytes,
                    .cpuPressureSomeAvg10,
                    .cpuPressureFullAvg10,
                    .memoryPressureSomeAvg10,
                    .memoryPressureFullAvg10,
                    .ioPressureSomeAvg10,
                    .ioPressureFullAvg10
                ] as $measurements
                | (
                    .cpuUtilizationPercent != null
                    and .load1 != null
                    and .load5 != null
                    and .load15 != null
                    and .memoryTotalBytes != null
                    and .memoryAvailableBytes != null
                    and .swapUsedBytes != null
                ) as $coreAvailable
                | if .status == "available" then
                    $coreAvailable
                  elif .status == "partial" then
                    ($coreAvailable | not)
                    and any($measurements[]; . != null)
                  else
                    all($measurements[]; . == null)
                  end
            );
        def valid_resource_telemetry:
            type == "object"
            and has("host")
            and has("manager")
            and (.sampledAt | type == "string" and length > 0)
            and (
                .status == "available"
                or .status == "partial"
                or .status == "unavailable"
            )
            and (.host == null or (.host | valid_host_capacity))
            and (.hostPressure == null or (.hostPressure | valid_host_pressure))
            and (.manager == null or (.manager | valid_resource_usage));
        def valid_autoscaling:
            type == "object"
            and .mode == "scale-set"
            and (
                .status == "starting"
                or .status == "running"
                or .status == "degraded"
                or .status == "stopping"
            )
            and (.minimumIdleSlots | nonnegative_integer)
            and (.maximumSlots | nonnegative_integer)
            and (.targetSlots | nonnegative_integer)
            and (.assignedJobs | nonnegative_integer)
            and (.runningJobs | nonnegative_integer)
            and (.availableJobs | nonnegative_integer)
            and (.idleRunners | nonnegative_integer)
            and (.busyRunners | nonnegative_integer)
            and (.scaleDownDelaySeconds | nonnegative_integer)
            and (.scaleDownAt == null or (.scaleDownAt | type == "string" and length > 0))
            and (.scaleSetCount | nonnegative_integer)
            and (.lastError == null or (.lastError | type == "string"));
        def valid_update:
            type == "object"
            and (.status == "current" or .status == "rolling" or .status == "degraded")
            and (
                .targetImage == null
                or (
                    .targetImage
                    | type == "string"
                    and length >= 1
                    and length <= 2048
                    and test("^\\S+$")
                )
            )
            and (
                .targetImageId == null
                or (
                    .targetImageId
                    | type == "string"
                    and test("^sha256:[0-9a-f]{64}$")
                )
            )
            and (.targetRevision | type == "string" and test("^[0-9a-f]{64}$"))
            and (.currentWorkers | nonnegative_integer)
            and (.staleWorkers | nonnegative_integer)
            and (.lastError == null or (.lastError | type == "string"));
        def valid_sanitized_evidence:
            . == null
            or (
                type == "string"
                and length <= 160
                and test("^[A-Za-z0-9][A-Za-z0-9 .,_()'"'"'-]*$")
            );
        def valid_event_operation:
            . as $operation
            | [
                "docker-ping", "docker-run", "docker-inspect", "docker-remove",
                "docker-events", "registration-token-request", "runner-registration",
                "runner-removal", "session-create", "session-refresh", "session-delete",
                "message-poll", "message-acknowledge", "jit-config-generate",
                "worker-launch", "worker-exit", "telemetry-sample", "desired-state-load",
                "desired-state-apply", "capacity-acknowledge", "observed-state-publish",
                "registration-cleanup", "container-cleanup", "admission-reserve",
                "admission-settle", "manager-start", "manager-shutdown", "journal-restore"
            ]
            | any(. == $operation);
        def valid_event_reason:
            . as $reason
            | [
                "none", "docker-unavailable", "docker-failed", "timeout", "rate-limited",
                "authorization-failed", "not-found", "conflict", "invalid-state",
                "capacity-ceiling", "retry-backoff", "cancelled", "recovered", "unknown"
            ]
            | any(. == $reason);
        def valid_manager_event:
            type == "object"
            and (.sequence | nonnegative_integer and . >= 1)
            and (.managerInstanceId | type == "string" and length > 0 and length <= 128)
            and (.observedAt | type == "string" and length > 0)
            and (
                .subsystem as $subsystem
                | [
                    "docker", "registration", "scale-set-session", "listener", "jit",
                    "worker-launch", "worker-exit", "telemetry", "reconciliation",
                    "cleanup", "admission", "recovery"
                ]
                | any(. == $subsystem)
            )
            and (.operation | valid_event_operation)
            and (.target == null or (.target | type == "string" and length > 0 and length <= 128))
            and (
                .outcome as $outcome
                | [
                    "succeeded", "failed", "timed-out", "retry-scheduled", "blocked",
                    "recovered", "unknown"
                ]
                | any(. == $outcome)
            )
            and (
                .durationMilliseconds == null
                or (.durationMilliseconds | nonnegative_integer and . <= 86400000)
            )
            and (.attempt == null or (.attempt | nonnegative_integer and . >= 1 and . <= 1000))
            and (
                .consecutiveFailures == null
                or (.consecutiveFailures | nonnegative_integer and . <= 1000)
            )
            and (.retryAt == null or (.retryAt | type == "string" and length > 0))
            and (.reason | valid_event_reason)
            and has("evidence")
            and (.evidence | valid_sanitized_evidence)
            and (
                if .outcome == "succeeded" then
                    .reason == "none" or .reason == "recovered"
                else true end
            )
            and (
                if .outcome == "failed" or .outcome == "timed-out" or .outcome == "blocked" then
                    .reason != "none"
                else true end
            )
            and (if .outcome == "retry-scheduled" then .retryAt != null else true end);
        def valid_operation_journal:
            type == "object"
            and (.status == "current" or .status == "truncated" or .status == "unavailable")
            and (.capacity | nonnegative_integer and . >= 1 and . <= 64)
            and (.highestSequence == null or (.highestSequence | nonnegative_integer and . >= 1))
            and (.droppedEvents | nonnegative_integer)
            and (.events | type == "array")
            and (.events | length) <= 64
            and (.events | length) <= .capacity
            and all(.events[]; valid_manager_event)
            and (([.events[].sequence] | unique | length) == (.events | length))
            and (if .status == "unavailable" then
                    (.events | length) == 0 and .highestSequence == null
                else true end)
            and (if .status == "truncated" then .droppedEvents >= 1 else true end)
            and (if (.events | length) > 0 then
                    .highestSequence == ([.events[].sequence] | max)
                else true end)
            and ((. | tojson | length) <= 16384);
        def valid_subsystem_evidence:
            type == "object"
            and (.operation | valid_event_operation)
            and (.observedAt | type == "string" and length > 0)
            and (
                .durationMilliseconds == null
                or (.durationMilliseconds | nonnegative_integer and . <= 86400000)
            )
            and (.reason | valid_event_reason)
            and (.evidence | valid_sanitized_evidence);
        def valid_subsystem_summary:
            type == "object"
            and (
                .state == "healthy"
                or .state == "degraded"
                or .state == "unavailable"
                or .state == "unknown"
            )
            and (.observedAt | type == "string" and length > 0)
            and (.consecutiveFailures | nonnegative_integer and . <= 1000)
            and (.retryAt == null or (.retryAt | type == "string" and length > 0))
            and (.lastSuccess == null or (.lastSuccess | valid_subsystem_evidence))
            and (.lastFailure == null or (.lastFailure | valid_subsystem_evidence))
            and (if .state == "healthy" then
                    .consecutiveFailures == 0 and .lastSuccess != null
                else true end)
            and (if .state == "degraded" or .state == "unavailable" then
                    .consecutiveFailures >= 1 and .lastFailure != null
                else true end)
            and (if .state == "unknown" then
                    .consecutiveFailures == 0
                    and .lastSuccess == null
                    and .lastFailure == null
                    and .retryAt == null
                else true end);
        def valid_subsystem_health:
            type == "object"
            and (.docker | valid_subsystem_summary)
            and (.github | valid_subsystem_summary);
        def valid_capacity_deficit:
            type == "object"
            and (.observedAt | type == "string" and length > 0)
            and (
                .freshness == "current"
                or .freshness == "stale"
                or .freshness == "unavailable"
            )
            and (.targetSlots | nonnegative_integer)
            and (.activeWorkers | nonnegative_integer)
            and (.startingWorkers | nonnegative_integer)
            and (.drainingWorkers | nonnegative_integer)
            and (.cleanupPendingWorkers | nonnegative_integer)
            and (.eligibleWorkers == null or (.eligibleWorkers | nonnegative_integer))
            and (.localDeficit | nonnegative_integer)
            and (.eligibilityDeficit == null or (.eligibilityDeficit | nonnegative_integer))
            and (
                .reason as $reason
                | [
                    "none", "admission-ceiling", "host-admission-withheld",
                    "host-admission-degraded",
                    "host-admission-unavailable", "launch-pending", "docker-unavailable",
                    "docker-failed", "jit-pending", "jit-failed", "listener-unavailable",
                    "session-unavailable", "registration-cleanup-pending", "worker-draining",
                    "invalid-desired-state", "retry-backoff", "unknown"
                ]
                | any(. == $reason)
            )
            and has("evidence")
            and (.evidence | valid_sanitized_evidence)
            and (if .localDeficit >= 1 then .reason != "none" else true end)
            and (
                if .eligibleWorkers == null then
                    .eligibilityDeficit == null
                else
                    .eligibilityDeficit != null
                end
            )
            and (
                if .freshness == "unavailable" then
                    .eligibleWorkers == null and .reason == "unknown"
                else true end
            );
        def valid_capacity_evidence:
            type == "object"
            and has("fixed")
            and (.targets | type == "array")
            and (.fixed == null or (.fixed | valid_capacity_deficit));
        def valid_bounded_text($maximum):
            type == "string"
            and length >= 1
            and length <= $maximum
            and (
                explode
                | map(select(. < 32 or . == 127))
                | length == 0
            );
        def valid_current_job:
            type == "object"
            and (
                keys == [
                    "displayName",
                    "eventName",
                    "finishedAt",
                    "jobId",
                    "queuedAt",
                    "repository",
                    "result",
                    "runnerAssignedAt",
                    "scaleSetAssignedAt",
                    "startedAt",
                    "workflowRunId"
                ]
            )
            and (
                .repository
                | type == "string"
                and test("^https://github\\.com/[A-Za-z0-9._-]{1,39}/[A-Za-z0-9._-]{1,100}$")
            )
            and (.workflowRunId | nonnegative_integer and . >= 1)
            and (
                .jobId
                | type == "string"
                and test("^[1-9][0-9]{0,31}$")
            )
            and (
                .displayName == null
                or (
                    .displayName
                    | valid_bounded_text(256)
                )
            )
            and (
                .eventName == null
                or (
                    .eventName
                    | valid_bounded_text(64)
                )
            )
            and (.queuedAt == null or (.queuedAt | type == "string" and length > 0))
            and (
                .scaleSetAssignedAt == null
                or (.scaleSetAssignedAt | type == "string" and length > 0)
            )
            and (
                .runnerAssignedAt == null
                or (.runnerAssignedAt | type == "string" and length > 0)
            )
            and (.startedAt | type == "string" and length > 0)
            and (.finishedAt == null or (.finishedAt | type == "string" and length > 0))
            and (
                .result == null
                or (
                    .result
                    | valid_bounded_text(64)
                )
            );
        def valid_slot:
            type == "object"
            and (.key | type == "string" and length > 0)
            and (.repository == null or (.repository | type == "string"))
            and (.desired | type == "boolean")
            and (.processRunning | type == "boolean")
            and (
                .state == "starting"
                or .state == "online"
                or .state == "backoff"
                or .state == "restarting"
                or .state == "draining"
                or .state == "stopped"
            )
            and (.failureCount | nonnegative_integer)
            and (.backoffSeconds | nonnegative_integer)
            and (.updatedAt == null or (.updatedAt | type == "string" and length > 0))
            and (.resources == null or (.resources | valid_resource_usage))
            and (
                .activity == null
                or .activity == "starting"
                or .activity == "idle"
                or .activity == "busy"
                or .activity == "draining"
                or .activity == "unknown"
            )
            and (.target == null or (.target | type == "string" and length > 0))
            and (
                .imageId == null
                or (.imageId | type == "string" and test("^sha256:[0-9a-f]{64}$"))
            )
            and (
                .runnerNameHash == null
                or (
                    .runnerNameHash
                    | type == "string" and test("^[0-9a-f]{64}$")
                )
            )
            and (.currentJob == null or (.currentJob | valid_current_job))
            and (.lastExit == null or (.lastExit | valid_last_exit));
        def valid_registration_status:
            . == "connected"
            or . == "disconnected"
            or . == "registration-missing"
            or . == "unknown";
        type == "object"
        and .schemaVersion == 1
        and (.managerContractVersion | nonnegative_integer and . >= 1)
        and (.profileId | type == "string" and length > 0)
        and (.managerInstanceId | type == "string" and length > 0)
        and (
            .managerStatus == "starting"
            or .managerStatus == "running"
            or .managerStatus == "stopping"
            or .managerStatus == "stopped"
        )
        and (.observedAt | type == "string" and length > 0)
        and (.scope == "repo" or .scope == "org" or .scope == "ent")
        and (.generation | nonnegative_integer)
        and (.desiredStateHash == null or (.desiredStateHash | type == "string" and length > 0))
        and (
            .desiredStateStatus == "waiting"
            or .desiredStateStatus == "accepted"
            or .desiredStateStatus == "invalid"
            or .desiredStateStatus == "stale"
            or .desiredStateStatus == "conflict"
        )
        and (.desiredSlots | nonnegative_integer)
        and (.configuredSlots == null or (.configuredSlots | nonnegative_integer))
        and (.activeSlots | nonnegative_integer)
        and (.eligibleSlots == null or (.eligibleSlots | nonnegative_integer))
        and (.drainingSlots | nonnegative_integer)
        and (.slots | type == "array")
        and all(.slots[]; valid_slot)
        and (([.slots[].key] | unique | length) == (.slots | length))
        and (
            if .managerContractVersion >= 7 then
                has("resourceTelemetry")
                and (.resourceTelemetry | valid_resource_telemetry)
                and all(.slots[]; has("resources"))
            else
                (.resourceTelemetry == null or (.resourceTelemetry | valid_resource_telemetry))
            end
        )
        and (
            if .managerContractVersion >= 8 then
                has("configuredSlots")
                and has("autoscaling")
                and (.autoscaling == null or (.autoscaling | valid_autoscaling))
            else
                true
            end
        )
        and (
            if .managerContractVersion >= 9 then
                has("update")
                and (.update | valid_update)
            else
                true
            end
        )
        and (
            if .managerContractVersion >= 10 then
                has("eligibleSlots")
                and (.eligibleSlots | nonnegative_integer)
                and all(.slots[];
                    has("registrationStatus")
                    and (.registrationStatus | valid_registration_status))
                and .eligibleSlots == (
                    [.slots[] | select(.registrationStatus == "connected")]
                    | length
                )
            else
                true
            end
        )
        and (.resourcePolicy == null or (.resourcePolicy | valid_resource_policy))
        and (
            if .managerContractVersion >= 11 then
                has("resourcePolicy")
                and all(.slots[];
                    has("imageId")
                    and has("lastExit")
                    and (.resources == null or (.resources | valid_io_counters)))
            else
                true
            end
        )
        and (
            if .managerContractVersion >= 14 then
                all(.slots[];
                    has("runnerNameHash")
                    and (
                        .runnerNameHash == null
                        or (
                            .runnerNameHash
                            | type == "string" and test("^[0-9a-f]{64}$")
                        )
                    ))
            else
                true
            end
        )
        and (
            if .managerContractVersion >= 15 then
                all(.slots[];
                    has("currentJob")
                    and (
                        .currentJob == null
                        or (
                            .currentJob | valid_current_job
                        )
                    ))
            else
                true
            end
        )
        and (
            if .managerContractVersion >= 16 then
                .resourceTelemetry != null
                and (.resourceTelemetry | has("hostPressure"))
                and (.resourceTelemetry.hostPressure | valid_host_pressure)
            else
                true
            end
        )
        and (
            .hostAdmission == null
            or (.hostAdmission | valid_host_admission)
        )
        and (
            if .managerContractVersion >= 18 then
                has("hostAdmission")
                and .hostAdmission != null
            else
                true
            end
        )
        and (
            .operationJournal == null
            or (.operationJournal | valid_operation_journal)
        )
        and (
            .subsystemHealth == null
            or (.subsystemHealth | valid_subsystem_health)
        )
        and (
            .capacityEvidence == null
            or (.capacityEvidence | valid_capacity_evidence)
        )
        and (
            if .managerContractVersion >= 12 then
                has("operationJournal")
                and has("subsystemHealth")
                and has("capacityEvidence")
                and (.operationJournal | valid_operation_journal)
                and (.subsystemHealth | valid_subsystem_health)
                and (.capacityEvidence | valid_capacity_evidence)
                and (
                    if .autoscaling == null then
                        .capacityEvidence.fixed != null
                        and (.capacityEvidence.targets | length) == 0
                    else
                        .capacityEvidence.fixed == null
                    end
                )
                and (
                    if .managerContractVersion >= 13 then
                        has("host")
                        and (.host | type == "object")
                        and (.host | keys == ["hardware"])
                        and (.host.hardware | valid_host_hardware)
                    else
                        (
                            has("host") == false
                            or (
                                (.host | type == "object")
                                and (.host | keys == ["hardware"])
                                and (.host.hardware | valid_host_hardware)
                            )
                        )
                    end
                )
            else
                true
            end
        )
        and (
            .resourceTelemetry as $telemetry
            | if $telemetry == null then
                all(.slots[]; .resources == null)
              elif $telemetry.status == "available" then
                $telemetry.host != null
                and $telemetry.manager != null
              elif $telemetry.status == "partial" then
                $telemetry.host != null
                or $telemetry.manager != null
                or any(.slots[]; .resources != null)
              else
                $telemetry.host == null
                and $telemetry.manager == null
                and all(.slots[]; .resources == null)
              end
        )
    ' "$1" >/dev/null 2>&1
}

host_hardware_values_json() {
    jq -c -S '{
        processorModel,
        architecture,
        physicalCoreCount,
        logicalProcessorCount,
        performanceCoreCount,
        efficiencyCoreCount,
        memoryBytes,
        operatingSystem,
        kernelVersion,
        dockerServerVersion,
        dockerStorageDriver,
        dockerBackingFilesystem
    }'
}

host_hardware_inventory_is_valid() {
    inventory_path="$1"
    jq -e '
        def positive_integer:
            type == "number" and . > 0 and floor == .;
        def nullable_text($maximum):
            . == null
            or (
                type == "string"
                and length >= 1
                and length <= $maximum
                and (explode | all(. >= 32 and . != 127))
            );
        type == "object"
        and (
            .status == "current"
            or .status == "stale"
            or .status == "unavailable"
        )
        and (
            .collectedAt == null
            or (
                (.collectedAt | type == "string")
                and ((.collectedAt | fromdateiso8601?) | type == "number")
            )
        )
        and (
            (.attemptedAt | type == "string")
            and ((.attemptedAt | fromdateiso8601?) | type == "number")
        )
        and (
            .inventoryHash == null
            or (.inventoryHash | type == "string" and test("^[0-9a-f]{64}$"))
        )
        and (.processorModel | nullable_text(256))
        and (.architecture | nullable_text(64))
        and (.physicalCoreCount == null or (.physicalCoreCount | positive_integer))
        and (.logicalProcessorCount == null or (.logicalProcessorCount | positive_integer))
        and (.performanceCoreCount == null or (.performanceCoreCount | positive_integer))
        and (.efficiencyCoreCount == null or (.efficiencyCoreCount | positive_integer))
        and (.memoryBytes == null or (.memoryBytes | positive_integer))
        and (.operatingSystem | nullable_text(256))
        and (.kernelVersion | nullable_text(256))
        and (.dockerServerVersion | nullable_text(256))
        and (.dockerStorageDriver | nullable_text(256))
        and (.dockerBackingFilesystem | nullable_text(256))
        and (
            if .status == "unavailable" then
                .collectedAt == null
                and .inventoryHash == null
                and .processorModel == null
                and .architecture == null
                and .physicalCoreCount == null
                and .logicalProcessorCount == null
                and .performanceCoreCount == null
                and .efficiencyCoreCount == null
                and .memoryBytes == null
                and .operatingSystem == null
                and .kernelVersion == null
                and .dockerServerVersion == null
                and .dockerStorageDriver == null
                and .dockerBackingFilesystem == null
            else
                .collectedAt != null
                and .inventoryHash != null
            end
        )
    ' "${inventory_path}" >/dev/null 2>&1 || return 1
    status=$(jq -r '.status' "${inventory_path}")
    [ "${status}" = "unavailable" ] && return 0
    expected_hash=$(jq -cj '{
        processorModel,
        architecture,
        physicalCoreCount,
        logicalProcessorCount,
        performanceCoreCount,
        efficiencyCoreCount,
        memoryBytes,
        operatingSystem,
        kernelVersion,
        dockerServerVersion,
        dockerStorageDriver,
        dockerBackingFilesystem
    }' "${inventory_path}" | sha256sum | cut -d ' ' -f1)
    [ "${expected_hash}" = "$(jq -r '.inventoryHash' "${inventory_path}")" ]
}

write_unavailable_host_hardware() (
    output_path="$1"
    attempted_at="${2:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    temporary="${output_path%/*}/.host-hardware.$$.tmp"
    jq -n \
        --arg attemptedAt "${attempted_at}" \
        '{
            status: "unavailable",
            collectedAt: null,
            attemptedAt: $attemptedAt,
            inventoryHash: null,
            processorModel: null,
            architecture: null,
            physicalCoreCount: null,
            logicalProcessorCount: null,
            performanceCoreCount: null,
            efficiencyCoreCount: null,
            memoryBytes: null,
            operatingSystem: null,
            kernelVersion: null,
            dockerServerVersion: null,
            dockerStorageDriver: null,
            dockerBackingFilesystem: null
        }' > "${temporary}" || {
            rm -f "${temporary}"
            return 1
        }
    mv -f "${temporary}" "${output_path}"
)

write_stale_or_unavailable_host_hardware() (
    source_path="$1"
    output_path="$2"
    attempted_at="${3:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    temporary="${output_path%/*}/.host-hardware-fallback.$$.tmp"
    if [ -f "${source_path}" ] &&
        host_hardware_inventory_is_valid "${source_path}" &&
        [ "$(jq -r '.inventoryHash // ""' "${source_path}")" != "" ]; then
        jq \
            --arg attemptedAt "${attempted_at}" \
            '.status = "stale" | .attemptedAt = $attemptedAt' \
            "${source_path}" > "${temporary}" || {
                rm -f "${temporary}"
                return 1
            }
    else
        write_unavailable_host_hardware "${temporary}" "${attempted_at}" || return 1
    fi
    mv -f "${temporary}" "${output_path}"
)

collect_host_hardware() (
    output_path="$1"
    command_timeout="$2"
    cpuinfo_path="${3:-/proc/cpuinfo}"
    kernel_path="${4:-/proc/sys/kernel/osrelease}"
    architecture_value="${5:-$(uname -m 2>/dev/null || true)}"
    case "${command_timeout}" in
        ''|*[!0-9]*|0) exit 1 ;;
    esac
    attempted_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    working_directory="${output_path%/*}/.host-hardware.$$"
    candidate_path="${working_directory}/candidate.json"
    docker_info_path="${working_directory}/docker-info.json"
    temporary="${output_path%/*}/.host-hardware.$$.tmp"
    mkdir -p "${working_directory}" || exit 1
    trap 'rm -rf "${working_directory}" "${temporary}"' EXIT
    printf '{}\n' > "${docker_info_path}"

    docker_info_available=0
    if timeout "${command_timeout}" docker info \
        --format '{"logicalProcessorCount":{{.NCPU}},"memoryBytes":{{.MemTotal}},"operatingSystem":{{json .OperatingSystem}},"dockerServerVersion":{{json .ServerVersion}},"dockerStorageDriver":{{json .Driver}}}' \
        > "${docker_info_path}.candidate" 2>/dev/null &&
        jq -e '
            (.logicalProcessorCount | type == "number" and . > 0 and floor == .)
            and (.memoryBytes | type == "number" and . > 0 and floor == .)
            and (.operatingSystem | type == "string")
            and (.dockerServerVersion | type == "string")
            and (.dockerStorageDriver | type == "string")
        ' "${docker_info_path}.candidate" >/dev/null 2>&1; then
        mv -f "${docker_info_path}.candidate" "${docker_info_path}"
        docker_info_available=1
    else
        rm -f "${docker_info_path}.candidate"
    fi

    docker_backing_filesystem=$(
        timeout "${command_timeout}" docker info \
            --format '{{range .DriverStatus}}{{if eq (index . 0) "Backing Filesystem"}}{{index . 1}}{{end}}{{end}}' \
            2>/dev/null || true
    )
    processor_model=""
    physical_core_count=""
    if [ -f "${cpuinfo_path}" ]; then
        processor_model=$(
            awk -F: '
                {
                    key=$1
                    gsub(/^[ \t]+|[ \t]+$/, "", key)
                    if (key == "model name" || key == "Processor" || key == "Hardware") {
                        value=$2
                        gsub(/^[ \t]+|[ \t]+$/, "", value)
                        if (value != "") {
                            print value
                            exit
                        }
                    }
                }
            ' "${cpuinfo_path}"
        )
        physical_core_count=$(
            awk -F: '
                function flush_record() {
                    if (!has_processor) return
                    processors++
                    if (physical_id != "" && core_id != "") {
                        complete++
                        cores[physical_id ":" core_id]=1
                    }
                    has_processor=0
                    physical_id=""
                    core_id=""
                }
                /^[[:space:]]*$/ { flush_record(); next }
                {
                    key=$1
                    value=$2
                    gsub(/^[ \t]+|[ \t]+$/, "", key)
                    gsub(/^[ \t]+|[ \t]+$/, "", value)
                    if (key == "processor") has_processor=1
                    if (key == "physical id") physical_id=value
                    if (key == "core id") core_id=value
                }
                END {
                    flush_record()
                    if (processors > 0 && complete == processors) {
                        count=0
                        for (key in cores) count++
                        if (count > 0) print count
                    }
                }
            ' "${cpuinfo_path}"
        )
    fi
    kernel_version=""
    [ -f "${kernel_path}" ] && kernel_version=$(cat "${kernel_path}" 2>/dev/null || true)
    case "${architecture_value}" in
        x86_64|amd64) architecture_value="amd64" ;;
        aarch64|arm64) architecture_value="arm64" ;;
        armv7*|armv6*) architecture_value="arm" ;;
        i386|i486|i586|i686) architecture_value="386" ;;
    esac

    jq -n \
        --arg processorModel "${processor_model}" \
        --arg architecture "${architecture_value}" \
        --arg physicalCoreCount "${physical_core_count}" \
        --arg kernelVersion "${kernel_version}" \
        --arg dockerBackingFilesystem "${docker_backing_filesystem}" \
        --slurpfile dockerInfo "${docker_info_path}" \
        '
            def bounded_text($maximum):
                gsub("\\s+"; " ")
                | gsub("^ +| +$"; "")
                | if length >= 1 and length <= $maximum
                  then .
                  else null
                  end;
            {
                processorModel: ($processorModel | bounded_text(256)),
                architecture: ($architecture | bounded_text(64)),
                physicalCoreCount: (
                    $physicalCoreCount
                    | tonumber?
                    | if . != null and . > 0 and floor == . then . else null end
                ),
                logicalProcessorCount: (
                    $dockerInfo[0].logicalProcessorCount
                    | if type == "number" and . > 0 and floor == . then . else null end
                ),
                performanceCoreCount: null,
                efficiencyCoreCount: null,
                memoryBytes: (
                    $dockerInfo[0].memoryBytes
                    | if type == "number" and . > 0 and floor == . then . else null end
                ),
                operatingSystem: (
                    ($dockerInfo[0].operatingSystem // "")
                    | bounded_text(256)
                ),
                kernelVersion: ($kernelVersion | bounded_text(256)),
                dockerServerVersion: (
                    ($dockerInfo[0].dockerServerVersion // "")
                    | bounded_text(256)
                ),
                dockerStorageDriver: (
                    ($dockerInfo[0].dockerStorageDriver // "")
                    | bounded_text(256)
                ),
                dockerBackingFilesystem: (
                    $dockerBackingFilesystem | bounded_text(256)
                )
            }
        ' > "${candidate_path}" || exit 1

    candidate_available=$(jq '
        [
            .processorModel,
            .architecture,
            .physicalCoreCount,
            .logicalProcessorCount,
            .performanceCoreCount,
            .efficiencyCoreCount,
            .memoryBytes,
            .operatingSystem,
            .kernelVersion,
            .dockerServerVersion,
            .dockerStorageDriver,
            .dockerBackingFilesystem
        ]
        | map(select(. != null))
        | length > 0
    ' "${candidate_path}")
    if [ "${docker_info_available}" = "1" ] &&
        [ "${candidate_available}" = "true" ]; then
        candidate_hash=$(jq -cj . "${candidate_path}" | sha256sum | cut -d ' ' -f1)
        collected_at="${attempted_at}"
        if [ -f "${output_path}" ] &&
            host_hardware_inventory_is_valid "${output_path}" &&
            [ "$(jq -r '.inventoryHash // ""' "${output_path}")" = "${candidate_hash}" ]; then
            collected_at=$(jq -r '.collectedAt' "${output_path}")
        fi
        jq -n \
            --arg collectedAt "${collected_at}" \
            --arg attemptedAt "${attempted_at}" \
            --arg inventoryHash "${candidate_hash}" \
            --slurpfile values "${candidate_path}" \
            '$values[0] + {
                status: "current",
                collectedAt: $collectedAt,
                attemptedAt: $attemptedAt,
                inventoryHash: $inventoryHash
            }' > "${temporary}" || exit 1
    elif [ -f "${output_path}" ] &&
        host_hardware_inventory_is_valid "${output_path}" &&
        [ "$(jq -r '.inventoryHash // ""' "${output_path}")" != "" ]; then
        jq \
            --arg attemptedAt "${attempted_at}" \
            '.status = "stale" | .attemptedAt = $attemptedAt' \
            "${output_path}" > "${temporary}" || exit 1
    else
        unavailable_path="${working_directory}/unavailable.json"
        write_unavailable_host_hardware "${unavailable_path}" "${attempted_at}" || exit 1
        cp "${unavailable_path}" "${temporary}" || exit 1
    fi
    host_hardware_inventory_is_valid "${temporary}" || exit 1
    mv -f "${temporary}" "${output_path}"
)

parse_size_bytes() (
    compact_value=$(printf '%s' "$1" | tr -d '[:space:]')
    number_value=$(printf '%s' "${compact_value}" | sed -n 's/^\([0-9][0-9.]*\)[A-Za-z]*$/\1/p')
    unit_value=$(printf '%s' "${compact_value}" | sed -n 's/^[0-9][0-9.]*\([A-Za-z]*\)$/\1/p')
    [ -n "${number_value}" ] || exit 1

    case "${unit_value}" in
        B|'') multiplier=1 ;;
        kB|KB) multiplier=1000 ;;
        MB) multiplier=1000000 ;;
        GB) multiplier=1000000000 ;;
        TB) multiplier=1000000000000 ;;
        KiB) multiplier=1024 ;;
        MiB) multiplier=1048576 ;;
        GiB) multiplier=1073741824 ;;
        TiB) multiplier=1099511627776 ;;
        *) exit 1 ;;
    esac

    jq -nr \
        --arg numberValue "${number_value}" \
        --argjson multiplier "${multiplier}" \
        '($numberValue | tonumber) * $multiplier | round'
)

parse_cpu_cores() (
    percent_value="$1"
    case "${percent_value}" in
        *%) ;;
        *) exit 1 ;;
    esac
    number_value=${percent_value%\%}
    jq -nr \
        --arg numberValue "${number_value}" \
        '($numberValue | tonumber) / 100'
)

parse_paired_size_bytes() (
    paired_value="$1"
    field_index="$2"
    case "${paired_value}" in
        *'/'*) ;;
        *) printf 'null\n'; exit 0 ;;
    esac
    if [ "${field_index}" = "1" ]; then
        component=${paired_value%%/*}
    else
        component=${paired_value#*/}
    fi
    component=$(printf '%s' "${component}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    if ! parsed_bytes=$(parse_size_bytes "${component}"); then
        printf 'null\n'
        exit 0
    fi
    printf '%s\n' "${parsed_bytes}"
)

write_slot_exit_evidence() {
    slot_state_path="$1"
    observed_dirty_path="$2"
    exit_evidence="$3"
    exit_code="$4"
    exit_oom_killed="$5"

    case "${exit_evidence}" in
        docker-inspect|docker-wait|launch|unavailable) ;;
        *) return 1 ;;
    esac
    case "${exit_code}" in
        '') ;;
        *[!0-9]*) return 1 ;;
        *) [ "${exit_code}" -le 255 ] || exit_code="" ;;
    esac
    case "${exit_oom_killed}" in
        true|false|'') ;;
        *) return 1 ;;
    esac

    exit_signal=""
    if [ -n "${exit_code}" ] && [ "${exit_code}" -gt 128 ] && [ "${exit_code}" -le 192 ]; then
        exit_signal=$((exit_code - 128))
    fi
    if [ "${exit_oom_killed}" = "true" ]; then
        exit_classification="oom-killed"
    elif [ "${exit_signal}" = "9" ]; then
        exit_classification="sigkill"
    elif [ -n "${exit_signal}" ]; then
        exit_classification="signal"
    elif [ "${exit_code}" = "0" ]; then
        exit_classification="clean"
    elif [ -n "${exit_code}" ]; then
        exit_classification="error"
    elif [ "${exit_evidence}" = "launch" ]; then
        exit_classification="launch-failure"
    else
        exit_classification="unknown"
    fi

    exit_temporary="${slot_state_path}/.last-exit.$$.tmp"
    if ! jq -n \
        --arg observedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg classification "${exit_classification}" \
        --arg exitCode "${exit_code}" \
        --arg signal "${exit_signal}" \
        --arg dockerOomKilled "${exit_oom_killed}" \
        --arg evidence "${exit_evidence}" \
        '{
            observedAt: $observedAt,
            classification: $classification,
            exitCode: (if $exitCode == "" then null else ($exitCode | tonumber) end),
            signal: (if $signal == "" then null else ($signal | tonumber) end),
            dockerOomKilled: (
                if $dockerOomKilled == "" then null else ($dockerOomKilled == "true") end
            ),
            evidence: $evidence
        }' > "${exit_temporary}"; then
        rm -f "${exit_temporary}"
        return 1
    fi
    if ! mv -f "${exit_temporary}" "${slot_state_path}/last-exit.json"; then
        rm -f "${exit_temporary}"
        return 1
    fi
    [ -n "${observed_dirty_path}" ] && : > "${observed_dirty_path}"
    return 0
}

normalize_container_resource_usage() (
    stats_record="$1"
    cpu_percent=$(printf '%s' "${stats_record}" | jq -r '.CPUPerc // empty')
    memory_usage=$(printf '%s' "${stats_record}" | jq -r '.MemUsage // empty')
    pids=$(printf '%s' "${stats_record}" | jq -r '.PIDs // empty')
    network_io=$(printf '%s' "${stats_record}" | jq -r '.NetIO // empty')
    block_io=$(printf '%s' "${stats_record}" | jq -r '.BlockIO // empty')
    memory_working_set=${memory_usage%%/*}
    memory_working_set=$(printf '%s' "${memory_working_set}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

    cpu_cores=$(parse_cpu_cores "${cpu_percent}") || exit 1
    memory_bytes=$(parse_size_bytes "${memory_working_set}") || exit 1
    case "${pids}" in
        ''|*[!0-9]*) exit 1 ;;
    esac
    network_rx_bytes=$(parse_paired_size_bytes "${network_io}" 1)
    network_tx_bytes=$(parse_paired_size_bytes "${network_io}" 2)
    block_read_bytes=$(parse_paired_size_bytes "${block_io}" 1)
    block_write_bytes=$(parse_paired_size_bytes "${block_io}" 2)

    jq -n \
        --argjson cpuCores "${cpu_cores}" \
        --argjson memoryWorkingSetBytes "${memory_bytes}" \
        --argjson pids "${pids}" \
        --argjson networkRxBytes "${network_rx_bytes}" \
        --argjson networkTxBytes "${network_tx_bytes}" \
        --argjson blockReadBytes "${block_read_bytes}" \
        --argjson blockWriteBytes "${block_write_bytes}" \
        '{
            cpuCores: $cpuCores,
            memoryWorkingSetBytes: $memoryWorkingSetBytes,
            pids: $pids,
            networkRxBytes: $networkRxBytes,
            networkTxBytes: $networkTxBytes,
            blockReadBytes: $blockReadBytes,
            blockWriteBytes: $blockWriteBytes
        }'
)

write_unavailable_resource_telemetry() {
    output_path="$1"
    temporary_path="${output_path%/*}/.resource-telemetry.$$.tmp"
    if ! jq -n \
        --arg sampledAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            sampledAt: $sampledAt,
            status: "unavailable",
            host: null,
            hostPressure: {
                status: "unavailable",
                source: "docker-host",
                cpuUtilizationPercent: null,
                load1: null,
                load5: null,
                load15: null,
                memoryTotalBytes: null,
                memoryAvailableBytes: null,
                swapUsedBytes: null,
                cpuPressureSomeAvg10: null,
                cpuPressureFullAvg10: null,
                memoryPressureSomeAvg10: null,
                memoryPressureFullAvg10: null,
                ioPressureSomeAvg10: null,
                ioPressureFullAvg10: null
            },
            manager: null,
            slots: {}
        }' > "${temporary_path}"; then
        rm -f "${temporary_path}"
        return 1
    fi
    if ! mv -f "${temporary_path}" "${output_path}"; then
        rm -f "${temporary_path}"
        return 1
    fi
}

collect_host_pressure() (
    proc_path="$1"
    baseline_path="$2"
    output_path="$3"
    cpu_utilization="null"
    load_1="null"
    load_5="null"
    load_15="null"
    memory_total="null"
    memory_available="null"
    swap_used="null"
    cpu_some="null"
    cpu_full="null"
    memory_some="null"
    memory_full="null"
    io_some="null"
    io_full="null"

    if counters=$(
        awk '
            $1 == "cpu" {
                if (NF < 5) exit 1
                limit = NF < 9 ? NF : 9
                total = 0
                for (i = 2; i <= limit; i++) {
                    if ($i !~ /^[0-9]+$/) exit 1
                    total += $i
                }
                idle = $5
                if (NF >= 6) idle += $6
                printf "%.0f %.0f\n", total, idle
                found = 1
                exit
            }
            END {
                if (!found) exit 1
            }
        ' "${proc_path}/stat" 2>/dev/null
    ); then
        current_total=${counters%% *}
        current_idle=${counters##* }
        if [ -f "${baseline_path}" ]; then
            previous_total=""
            previous_idle=""
            read -r previous_total previous_idle < "${baseline_path}" || true
            case "${previous_total}:${previous_idle}" in
                *[!0-9:]*|:|*:) ;;
                *)
                    if [ "${current_total}" -gt "${previous_total}" ] &&
                        [ "${current_idle}" -ge "${previous_idle}" ]; then
                        total_delta=$((current_total - previous_total))
                        idle_delta=$((current_idle - previous_idle))
                        if [ "${idle_delta}" -le "${total_delta}" ]; then
                            cpu_utilization=$(
                                awk \
                                    -v total="${total_delta}" \
                                    -v idle="${idle_delta}" \
                                    'BEGIN { printf "%.6f", ((total - idle) / total) * 100 }'
                            )
                        fi
                    fi
                    ;;
            esac
        fi
        baseline_temporary="${baseline_path}.$$.tmp"
        if printf '%s %s\n' "${current_total}" "${current_idle}" > "${baseline_temporary}"; then
            mv -f "${baseline_temporary}" "${baseline_path}" || rm -f "${baseline_temporary}"
        else
            rm -f "${baseline_temporary}"
        fi
    fi

    if loads=$(
        awk '
            NR == 1 {
                for (i = 1; i <= 3; i++) {
                    if ($i !~ /^[0-9]+([.][0-9]+)?$/) exit 1
                }
                print $1, $2, $3
                found = 1
                exit
            }
            END {
                if (!found) exit 1
            }
        ' "${proc_path}/loadavg" 2>/dev/null
    ); then
        load_1=$(printf '%s\n' "${loads}" | awk '{ print $1 }')
        load_5=$(printf '%s\n' "${loads}" | awk '{ print $2 }')
        load_15=$(printf '%s\n' "${loads}" | awk '{ print $3 }')
    fi

    if memory=$(
        awk '
            function bytes(value) {
                return value * 1024
            }
            /^MemTotal:/ {
                if ($2 !~ /^[0-9]+$/ || $3 != "kB") exit 1
                total = bytes($2)
                hasTotal = 1
            }
            /^MemAvailable:/ {
                if ($2 !~ /^[0-9]+$/ || $3 != "kB") exit 1
                available = bytes($2)
                hasAvailable = 1
            }
            /^SwapTotal:/ {
                if ($2 !~ /^[0-9]+$/ || $3 != "kB") exit 1
                swapTotal = bytes($2)
                hasSwapTotal = 1
            }
            /^SwapFree:/ {
                if ($2 !~ /^[0-9]+$/ || $3 != "kB") exit 1
                swapFree = bytes($2)
                hasSwapFree = 1
            }
            END {
                if (!hasTotal || !hasAvailable ||
                    total <= 0 || available < 0 || available > total) exit 1
                if (hasSwapTotal && hasSwapFree && swapFree <= swapTotal) {
                    printf "%.0f %.0f %.0f\n", total, available, swapTotal - swapFree
                } else {
                    printf "%.0f %.0f null\n", total, available
                }
            }
        ' "${proc_path}/meminfo" 2>/dev/null
    ); then
        memory_total=$(printf '%s\n' "${memory}" | awk '{ print $1 }')
        memory_available=$(printf '%s\n' "${memory}" | awk '{ print $2 }')
        swap_used=$(printf '%s\n' "${memory}" | awk '{ print $3 }')
    fi

    psi_avg10() {
        kind="$1"
        path="$2"
        awk -v kind="${kind}" '
            $1 == kind {
                for (i = 2; i <= NF; i++) {
                    split($i, pair, "=")
                    if (pair[1] == "avg10" &&
                        pair[2] ~ /^[0-9]+([.][0-9]+)?$/ &&
                        pair[2] + 0 <= 100) {
                        print pair[2]
                        exit
                    }
                }
            }
        ' "${path}" 2>/dev/null
    }

    value=$(psi_avg10 some "${proc_path}/pressure/cpu" || true)
    [ -n "${value}" ] && cpu_some="${value}"
    value=$(psi_avg10 full "${proc_path}/pressure/cpu" || true)
    [ -n "${value}" ] && cpu_full="${value}"
    value=$(psi_avg10 some "${proc_path}/pressure/memory" || true)
    [ -n "${value}" ] && memory_some="${value}"
    value=$(psi_avg10 full "${proc_path}/pressure/memory" || true)
    [ -n "${value}" ] && memory_full="${value}"
    value=$(psi_avg10 some "${proc_path}/pressure/io" || true)
    [ -n "${value}" ] && io_some="${value}"
    value=$(psi_avg10 full "${proc_path}/pressure/io" || true)
    [ -n "${value}" ] && io_full="${value}"

    core_available=0
    if [ "${cpu_utilization}" != "null" ] &&
        [ "${load_1}" != "null" ] &&
        [ "${load_5}" != "null" ] &&
        [ "${load_15}" != "null" ] &&
        [ "${memory_total}" != "null" ] &&
        [ "${memory_available}" != "null" ] &&
        [ "${swap_used}" != "null" ]; then
        core_available=1
    fi
    measurement_count=0
    for measurement in \
        "${cpu_utilization}" \
        "${load_1}" \
        "${load_5}" \
        "${load_15}" \
        "${memory_total}" \
        "${memory_available}" \
        "${swap_used}" \
        "${cpu_some}" \
        "${cpu_full}" \
        "${memory_some}" \
        "${memory_full}" \
        "${io_some}" \
        "${io_full}"; do
        [ "${measurement}" = "null" ] || measurement_count=$((measurement_count + 1))
    done
    if [ "${core_available}" -eq 1 ]; then
        status="available"
    elif [ "${measurement_count}" -gt 0 ]; then
        status="partial"
    else
        status="unavailable"
    fi

    jq -n \
        --arg status "${status}" \
        --argjson cpuUtilizationPercent "${cpu_utilization}" \
        --argjson load1 "${load_1}" \
        --argjson load5 "${load_5}" \
        --argjson load15 "${load_15}" \
        --argjson memoryTotalBytes "${memory_total}" \
        --argjson memoryAvailableBytes "${memory_available}" \
        --argjson swapUsedBytes "${swap_used}" \
        --argjson cpuPressureSomeAvg10 "${cpu_some}" \
        --argjson cpuPressureFullAvg10 "${cpu_full}" \
        --argjson memoryPressureSomeAvg10 "${memory_some}" \
        --argjson memoryPressureFullAvg10 "${memory_full}" \
        --argjson ioPressureSomeAvg10 "${io_some}" \
        --argjson ioPressureFullAvg10 "${io_full}" \
        '{
            status: $status,
            source: "docker-host",
            cpuUtilizationPercent: $cpuUtilizationPercent,
            load1: $load1,
            load5: $load5,
            load15: $load15,
            memoryTotalBytes: $memoryTotalBytes,
            memoryAvailableBytes: $memoryAvailableBytes,
            swapUsedBytes: $swapUsedBytes,
            cpuPressureSomeAvg10: $cpuPressureSomeAvg10,
            cpuPressureFullAvg10: $cpuPressureFullAvg10,
            memoryPressureSomeAvg10: $memoryPressureSomeAvg10,
            memoryPressureFullAvg10: $memoryPressureFullAvg10,
            ioPressureSomeAvg10: $ioPressureSomeAvg10,
            ioPressureFullAvg10: $ioPressureFullAvg10
        }' > "${output_path}"
)

collect_resource_telemetry() (
    output_path="$1"
    managed_label="$2"
    manager_label="$3"
    slot_label_key="$4"
    command_timeout="$5"
    case "${command_timeout}" in
        ''|*[!0-9]*|0) exit 1 ;;
    esac
    working_directory="${output_path%/*}/.resource-telemetry.$$"
    inventory_path="${working_directory}/inventory.tsv"
    ids_path="${working_directory}/ids.txt"
    raw_stats_path="${working_directory}/stats.jsonl"
    normalized_stats_path="${working_directory}/normalized.jsonl"
    host_path="${working_directory}/host.json"
    host_pressure_path="${working_directory}/host-pressure.json"
    output_temporary="${output_path%/*}/.resource-telemetry.$$.tmp"
    sampled_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    mkdir -p "${working_directory}" || exit 1
    trap 'rm -rf "${working_directory}" "${output_temporary}"' EXIT
    : > "${inventory_path}"
    : > "${raw_stats_path}"
    : > "${normalized_stats_path}"
    printf 'null\n' > "${host_path}"
    if ! collect_host_pressure \
        "${PITCREW_HOST_PROC_PATH:-/host/proc}" \
        "${output_path}.host-cpu-baseline" \
        "${host_pressure_path}"; then
        exit 1
    fi

    host_available=0
    if timeout "${command_timeout}" docker info \
        --format '{"logicalProcessorCount":{{.NCPU}},"memoryBytes":{{.MemTotal}}}' \
        > "${host_path}.candidate" 2>/dev/null &&
        jq -e '
            (.logicalProcessorCount | type == "number" and . > 0 and floor == .)
            and (.memoryBytes | type == "number" and . > 0 and floor == .)
        ' "${host_path}.candidate" >/dev/null 2>&1; then
        mv -f "${host_path}.candidate" "${host_path}"
        host_available=1
    else
        rm -f "${host_path}.candidate"
    fi

    manager_id="${HOSTNAME:-}"
    if [ -z "${manager_id}" ]; then
        manager_id=$(
            timeout "${command_timeout}" \
                docker ps -q --filter "label=${manager_label}" 2>/dev/null |
                head -n 1
        )
    fi
    if [ -n "${manager_id}" ]; then
        printf '%s\tmanager\t-\t-\n' "${manager_id}" >> "${inventory_path}"
    fi

    worker_inventory_available=0
    if timeout "${command_timeout}" docker ps \
        --filter "label=${managed_label}" \
        --format "{{.ID}} {{.Label \"${slot_label_key}\"}} {{.Names}}" \
        > "${working_directory}/workers.txt" 2>/dev/null; then
        worker_inventory_available=1
        while read -r worker_id worker_slot worker_name; do
            [ -n "${worker_id}" ] || continue
            [ -n "${worker_slot}" ] || continue
            printf '%s\tslot\t%s\t%s\n' \
                "${worker_id}" \
                "${worker_slot}" \
                "${worker_name}" >> "${inventory_path}"
        done < "${working_directory}/workers.txt"
    fi

    cut -f1 "${inventory_path}" > "${ids_path}"
    stats_command_available=1
    if [ -s "${ids_path}" ]; then
        if ! xargs timeout "${command_timeout}" docker stats \
            --no-stream \
            --format '{{json .}}' \
            < "${ids_path}" > "${raw_stats_path}" 2>/dev/null; then
            stats_command_available=0
        fi
    fi

    while IFS= read -r stats_record; do
        [ -n "${stats_record}" ] || continue
        container_id=$(printf '%s' "${stats_record}" | jq -r '.ID // .Container // empty' 2>/dev/null) || continue
        inventory_record=$(awk -F '\t' -v id="${container_id}" '$1 == id { print; exit }' "${inventory_path}")
        [ -n "${inventory_record}" ] || continue
        role=$(printf '%s' "${inventory_record}" | cut -f2)
        slot_key=$(printf '%s' "${inventory_record}" | cut -f3)
        runner_name=$(printf '%s' "${inventory_record}" | cut -f4)
        usage=$(normalize_container_resource_usage "${stats_record}") || continue
        jq -n -c \
            --arg role "${role}" \
            --arg slotKey "${slot_key}" \
            --arg runnerName "${runner_name}" \
            --argjson usage "${usage}" \
            '{
                role: $role,
                slotKey: $slotKey,
                runnerName: $runnerName,
                usage: $usage
            }' >> "${normalized_stats_path}" || exit 1
    done < "${raw_stats_path}"

    manager_available=$(jq -s '[.[] | select(.role == "manager")] | length' "${normalized_stats_path}")
    expected_workers=$(awk -F '\t' '$2 == "slot" { count++ } END { print count + 0 }' "${inventory_path}")
    observed_workers=$(jq -s '[.[] | select(.role == "slot")] | length' "${normalized_stats_path}")
    any_resource_available=$((host_available + manager_available + observed_workers))

    if [ "${host_available}" -eq 1 ] &&
        [ "${manager_available}" -eq 1 ] &&
        [ "${worker_inventory_available}" -eq 1 ] &&
        [ "${stats_command_available}" -eq 1 ] &&
        [ "${expected_workers}" -eq "${observed_workers}" ]; then
        telemetry_status="available"
    elif [ "${any_resource_available}" -gt 0 ]; then
        telemetry_status="partial"
    else
        telemetry_status="unavailable"
    fi

    if ! jq -n \
        --arg sampledAt "${sampled_at}" \
        --arg status "${telemetry_status}" \
        --slurpfile host "${host_path}" \
        --slurpfile hostPressure "${host_pressure_path}" \
        --slurpfile records "${normalized_stats_path}" \
        '{
            sampledAt: $sampledAt,
            status: $status,
            host: $host[0],
            hostPressure: $hostPressure[0],
            manager: (
                [$records[] | select(.role == "manager") | .usage][0] // null
            ),
            slots: (
                reduce (
                    $records[]
                    | select(.role == "slot")
                ) as $record (
                    {};
                    .[$record.slotKey] = {
                        runnerName: $record.runnerName,
                        usage: $record.usage
                    }
                )
            )
        }' > "${output_temporary}"; then
        exit 1
    fi
    mv -f "${output_temporary}" "${output_path}"
)

write_slot_runtime_state() {
    slot_state_path="$1"
    observed_dirty_path="$2"
    runtime_state="$3"
    runner_name="$4"
    failure_count="$5"
    backoff_seconds="$6"

    case "${runtime_state}" in
        starting|online|backoff|restarting) ;;
        *) return 1 ;;
    esac
    case "${failure_count}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    case "${backoff_seconds}" in
        ''|*[!0-9]*) return 1 ;;
    esac

    runtime_temporary="${slot_state_path}/.runtime-state.$$.tmp"
    if ! jq -n \
        --arg state "${runtime_state}" \
        --arg runnerName "${runner_name}" \
        --argjson failureCount "${failure_count}" \
        --argjson backoffSeconds "${backoff_seconds}" \
        --arg updatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            state: $state,
            runnerName: (if $runnerName == "" then null else $runnerName end),
            failureCount: $failureCount,
            backoffSeconds: $backoffSeconds,
            updatedAt: $updatedAt
        }' > "${runtime_temporary}"; then
        rm -f "${runtime_temporary}"
        return 1
    fi
    if ! mv -f "${runtime_temporary}" "${slot_state_path}/runtime-state.json"; then
        rm -f "${runtime_temporary}"
        return 1
    fi
    [ -n "${observed_dirty_path}" ] && : > "${observed_dirty_path}"
}

# A worker's connect marker is local process output, not authoritative GitHub
# connectivity, so it may only promote a slot whose runner this manager launched
# and watched from its first line. A fresh launch opens the transition, the
# first observed marker consumes it, and a slot adopted from a previous manager
# starts with it already consumed: log output produced before adoption is
# replayable and can never report recovered capacity as online.
reset_slot_connect_marker() {
    rm -f "$1/connected"
}

consume_slot_connect_marker() {
    : > "$1/connected"
}

slot_connect_marker_is_pending() {
    [ ! -f "$1/connected" ]
}

render_observed_slots() {
    slot_directory="$1"
    output_path="$2"
    resource_telemetry_path="$3"
    records_path="${output_path}.records"
    : > "${records_path}"

    if [ -d "${slot_directory}" ]; then
        for candidate_path in "${slot_directory}"/*; do
            [ -d "${candidate_path}" ] || continue
            slot_key=${candidate_path##*/}
            repository=""
            if [ -f "${candidate_path}/repo" ]; then
                repository=$(
                    sed \
                        -e 's/^[[:space:]]*//; s/[[:space:]]*$//' \
                        -e 's#^\([A-Za-z][A-Za-z0-9+.-]*://\)[^/@]*@#\1#' \
                        -e 's/[?#].*$//' \
                        "${candidate_path}/repo"
                )
            fi

            process_running=false
            if [ -f "${candidate_path}/pid" ]; then
                candidate_pid=$(cat "${candidate_path}/pid")
                if kill -0 "${candidate_pid}" 2>/dev/null; then
                    process_running=true
                fi
            fi

            runtime_state="starting"
            failure_count=0
            backoff_seconds=0
            updated_at=""
            runner_name=""
            registration_status="unknown"
            registration_activity=""
            runtime_path="${candidate_path}/runtime-state.json"
            runtime_snapshot="${output_path}.${slot_key}.runtime"
            if [ -f "${runtime_path}" ] &&
                cp "${runtime_path}" "${runtime_snapshot}" &&
                jq -e '
                type == "object"
                and (.state == "starting" or .state == "online" or .state == "backoff" or .state == "restarting")
                and (.failureCount | type == "number" and . >= 0 and floor == .)
                and (.backoffSeconds | type == "number" and . >= 0 and floor == .)
            ' "${runtime_snapshot}" >/dev/null 2>&1; then
                runtime_state=$(jq -r '.state' "${runtime_snapshot}")
                failure_count=$(jq -r '.failureCount' "${runtime_snapshot}")
                backoff_seconds=$(jq -r '.backoffSeconds' "${runtime_snapshot}")
                updated_at=$(jq -r '.updatedAt // ""' "${runtime_snapshot}")
                runner_name=$(jq -r '.runnerName // ""' "${runtime_snapshot}")
            fi
            rm -f "${runtime_snapshot}"
            registration_path="${candidate_path}/registration-state.json"
            registration_snapshot="${output_path}.${slot_key}.registration"
            if [ -f "${registration_path}" ] &&
                cp "${registration_path}" "${registration_snapshot}" &&
                jq -e '
                    type == "object"
                    and (
                        .status == "connected"
                        or .status == "disconnected"
                        or .status == "registration-missing"
                        or .status == "unknown"
                    )
                    and (
                        .activity == "starting"
                        or .activity == "idle"
                        or .activity == "busy"
                        or .activity == "draining"
                        or .activity == "unknown"
                    )
                ' "${registration_snapshot}" >/dev/null 2>&1; then
                registration_status=$(jq -r '.status' "${registration_snapshot}")
                registration_activity=$(jq -r '.activity' "${registration_snapshot}")
            fi
            rm -f "${registration_snapshot}"
            image_id=""
            if [ -f "${candidate_path}/image-id" ]; then
                image_id=$(cat "${candidate_path}/image-id")
                printf '%s' "${image_id}" |
                    grep -Eq '^sha256:[0-9a-f]{64}$' || image_id=""
            fi
            last_exit_path="${candidate_path}/last-exit.json"
            last_exit_snapshot="${output_path}.${slot_key}.last-exit"
            printf 'null\n' > "${last_exit_snapshot}"
            if [ -f "${last_exit_path}" ]; then
                last_exit_candidate="${last_exit_snapshot}.candidate"
                if cp "${last_exit_path}" "${last_exit_candidate}" &&
                    jq -e '
                        type == "object"
                        and (.observedAt | type == "string" and length > 0)
                        and (
                            .classification == "clean"
                            or .classification == "oom-killed"
                            or .classification == "sigkill"
                            or .classification == "signal"
                            or .classification == "error"
                            or .classification == "launch-failure"
                            or .classification == "unknown"
                        )
                        and (
                            .evidence == "docker-inspect"
                            or .evidence == "docker-wait"
                            or .evidence == "launch"
                            or .evidence == "unavailable"
                        )
                    ' "${last_exit_candidate}" >/dev/null 2>&1; then
                    mv -f "${last_exit_candidate}" "${last_exit_snapshot}"
                else
                    rm -f "${last_exit_candidate}"
                fi
            fi

            runner_name_hash=""
            case "${process_running}:${runtime_state}:${runner_name}" in
                true:starting:?*|true:online:?*)
                    runner_name_hash=$(
                        printf '%s' "${runner_name}" |
                            sha256sum |
                            cut -d ' ' -f1
                    )
                    ;;
            esac
            desired=true
            if [ -f "${candidate_path}/drain" ]; then
                desired=false
                runtime_state="draining"
            elif [ "${process_running}" != "true" ]; then
                runtime_state="stopped"
            fi

            jq -n -c \
                --arg key "${slot_key}" \
                --arg repository "${repository}" \
                --argjson desired "${desired}" \
                --argjson processRunning "${process_running}" \
                --arg state "${runtime_state}" \
                --argjson failureCount "${failure_count}" \
                --argjson backoffSeconds "${backoff_seconds}" \
                --arg updatedAt "${updated_at}" \
                --arg runnerName "${runner_name}" \
                --arg runnerNameHash "${runner_name_hash}" \
                --arg registrationStatus "${registration_status}" \
                --arg registrationActivity "${registration_activity}" \
                --arg imageId "${image_id}" \
                --slurpfile lastExit "${last_exit_snapshot}" \
                --slurpfile resourceTelemetry "${resource_telemetry_path}" \
                '{
                    key: $key,
                    repository: (if $repository == "" then null else $repository end),
                    desired: $desired,
                    processRunning: $processRunning,
                    state: $state,
                    failureCount: $failureCount,
                    backoffSeconds: $backoffSeconds,
                    updatedAt: (if $updatedAt == "" then null else $updatedAt end),
                    runnerNameHash: (
                        if $runnerNameHash == ""
                        then null
                        else $runnerNameHash
                        end
                    ),
                    currentJob: null,
                    registrationStatus: $registrationStatus,
                    activity: (
                        if $registrationActivity == ""
                        then null
                        else $registrationActivity
                        end
                    ),
                    resources: (
                        $resourceTelemetry[0].slots[$key] as $slotResources
                        | if $slotResources != null
                            and $slotResources.runnerName == $runnerName
                            and (
                                $state == "starting"
                                or $state == "online"
                                or $state == "draining"
                            )
                          then $slotResources.usage
                          else null
                          end
                    ),
                    imageId: (if $imageId == "" then null else $imageId end),
                    lastExit: $lastExit[0]
                }' >> "${records_path}" || {
                    rm -f "${records_path}" "${output_path}" "${last_exit_snapshot}"
                    return 1
                }
            rm -f "${last_exit_snapshot}"
        done
    fi

    if ! jq -s 'sort_by(.key)' "${records_path}" > "${output_path}"; then
        rm -f "${records_path}" "${output_path}"
        return 1
    fi
    rm -f "${records_path}"
}

remove_observed_policy_snapshot() {
    [ "$2" = "1" ] && rm -f "$1"
    return 0
}

remove_observed_optional_snapshots() {
    # Only manager-owned temporary projection paths reach this helper.
    # shellcheck disable=SC2086
    [ -n "$1" ] && rm -f $1
    return 0
}

publish_support_evidence_snapshot() (
    state_directory="$1"
    evidence_directory="${2:-${state_directory}/support-evidence}"

    state_owner=$(stat -c '%u:%g' "${state_directory}") || exit 1
    [ ! -L "${evidence_directory}" ] || exit 1
    if [ ! -d "${evidence_directory}" ]; then
        mkdir -p "${evidence_directory}" || exit 1
        chmod 0700 "${evidence_directory}" || exit 1
    fi
    chown "${state_owner}" "${evidence_directory}" || exit 1
    for file_name in \
        desired-capacity.json \
        acknowledged-capacity.json \
        static-profile.json \
        observed-state.json; do
        source_path="${state_directory}/${file_name}"
        destination_path="${evidence_directory}/${file_name}"
        if [ -L "${source_path}" ]; then
            rm -f "${destination_path}" || exit 1
            exit 1
        fi
        if [ ! -f "${source_path}" ]; then
            rm -f "${destination_path}" || exit 1
            continue
        fi
        temporary_path="${evidence_directory}/.${file_name}.$$.tmp"
        if ! cp "${source_path}" "${temporary_path}"; then
            rm -f "${temporary_path}"
            exit 1
        fi
        if ! chmod 0640 "${temporary_path}"; then
            rm -f "${temporary_path}"
            exit 1
        fi
        if ! mv -f "${temporary_path}" "${destination_path}"; then
            rm -f "${temporary_path}"
            exit 1
        fi
        chown "${state_owner}" "${destination_path}" || exit 1
    done
)

write_manager_observed_state() {
    output_path="$1"
    profile_id="$2"
    manager_instance_id="$3"
    manager_contract_version="$4"
    manager_status="$5"
    scope="$6"
    generation="$7"
    desired_state_hash="$8"
    desired_state_status="$9"
    desired_slots="${10}"
    slots_path="${11}"
    resource_telemetry_path="${12}"
    worker_revision="${13}"
    stale_workers="${14}"
    resource_policy_path="${15:-}"
    operation_journal_path="${16:-}"
    subsystem_health_path="${17:-}"
    capacity_evidence_path="${18:-}"
    target_image="${19:-}"
    target_image_id="${20:-}"
    host_hardware_path="${21:-}"
    host_admission_path="${22:-}"

    observed_optional_snapshots=""
    for optional_projection in operation_journal subsystem_health capacity_evidence host_admission; do
        case "${optional_projection}" in
            operation_journal) optional_path="${operation_journal_path}" ;;
            subsystem_health) optional_path="${subsystem_health_path}" ;;
            capacity_evidence) optional_path="${capacity_evidence_path}" ;;
            *) optional_path="${host_admission_path}" ;;
        esac
        if [ -z "${optional_path}" ] || [ ! -f "${optional_path}" ]; then
            optional_path="${output_path%/*}/.${optional_projection}.$$.tmp"
            printf 'null\n' > "${optional_path}" || return 1
            observed_optional_snapshots="${observed_optional_snapshots} ${optional_path}"
        fi
        case "${optional_projection}" in
            operation_journal) operation_journal_path="${optional_path}" ;;
            subsystem_health) subsystem_health_path="${optional_path}" ;;
            capacity_evidence) capacity_evidence_path="${optional_path}" ;;
            *) host_admission_path="${optional_path}" ;;
        esac
    done

    if [ -z "${resource_policy_path}" ] || [ ! -f "${resource_policy_path}" ]; then
        resource_policy_path="${output_path%/*}/.resource-policy.$$.tmp"
        printf 'null\n' > "${resource_policy_path}" || return 1
        remove_resource_policy_snapshot=1
    else
        remove_resource_policy_snapshot=0
    fi
    if [ -z "${host_hardware_path}" ] || [ ! -f "${host_hardware_path}" ]; then
        host_hardware_path="${output_path%/*}/.host_hardware.$$.tmp"
        write_unavailable_host_hardware "${host_hardware_path}" || return 1
        remove_host_hardware_snapshot=1
    else
        remove_host_hardware_snapshot=0
    fi

    observed_temporary="${output_path%/*}/.observed-state.$$.tmp"
    if ! jq -n \
        --argjson schemaVersion 1 \
        --argjson managerContractVersion "${manager_contract_version}" \
        --arg profileId "${profile_id}" \
        --arg managerInstanceId "${manager_instance_id}" \
        --arg managerStatus "${manager_status}" \
        --arg observedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg scope "${scope}" \
        --argjson generation "${generation}" \
        --arg desiredStateHash "${desired_state_hash}" \
        --arg desiredStateStatus "${desired_state_status}" \
        --argjson desiredSlots "${desired_slots}" \
        --slurpfile slots "${slots_path}" \
        --slurpfile resourceTelemetry "${resource_telemetry_path}" \
        --slurpfile resourcePolicy "${resource_policy_path}" \
        --slurpfile operationJournal "${operation_journal_path}" \
        --slurpfile subsystemHealth "${subsystem_health_path}" \
        --slurpfile capacityEvidence "${capacity_evidence_path}" \
        --slurpfile hostHardware "${host_hardware_path}" \
        --slurpfile hostAdmission "${host_admission_path}" \
        --arg workerRevision "${worker_revision}" \
        --arg targetImage "${target_image}" \
        --arg targetImageId "${target_image_id}" \
        --argjson staleWorkers "${stale_workers}" \
        '{
            schemaVersion: $schemaVersion,
            managerContractVersion: $managerContractVersion,
            profileId: $profileId,
            managerInstanceId: $managerInstanceId,
            managerStatus: $managerStatus,
            observedAt: $observedAt,
            scope: $scope,
            generation: $generation,
            desiredStateHash: (if $desiredStateHash == "" then null else $desiredStateHash end),
            desiredStateStatus: $desiredStateStatus,
            desiredSlots: $desiredSlots,
            configuredSlots: $desiredSlots,
            activeSlots: ($slots[0] | map(select(.processRunning)) | length),
            eligibleSlots: (
                $slots[0]
                | map(select(.registrationStatus == "connected"))
                | length
            ),
            drainingSlots: ($slots[0] | map(select(.state == "draining")) | length),
            slots: $slots[0],
            host: {
                hardware: $hostHardware[0]
            },
            resourceTelemetry: ($resourceTelemetry[0] | del(.slots)),
            resourcePolicy: $resourcePolicy[0],
            operationJournal: $operationJournal[0],
            subsystemHealth: $subsystemHealth[0],
            capacityEvidence: $capacityEvidence[0],
            hostAdmission: $hostAdmission[0],
            autoscaling: null,
            update: {
                status: (if $staleWorkers > 0 then "rolling" else "current" end),
                targetImage: (if $targetImage == "" then null else $targetImage end),
                targetImageId: (if $targetImageId == "" then null else $targetImageId end),
                targetRevision: $workerRevision,
                currentWorkers: (
                    (($slots[0] | map(select(.processRunning)) | length) - $staleWorkers)
                    | if . < 0 then 0 else . end
                ),
                staleWorkers: $staleWorkers,
                lastError: null
            }
        }' > "${observed_temporary}"; then
        remove_observed_policy_snapshot "${resource_policy_path}" "${remove_resource_policy_snapshot}"
        remove_observed_optional_snapshots "${observed_optional_snapshots}"
        [ "${remove_host_hardware_snapshot}" = "1" ] && rm -f "${host_hardware_path}"
        rm -f "${observed_temporary}"
        return 1
    fi
    remove_observed_policy_snapshot "${resource_policy_path}" "${remove_resource_policy_snapshot}"
    remove_observed_optional_snapshots "${observed_optional_snapshots}"
    [ "${remove_host_hardware_snapshot}" = "1" ] && rm -f "${host_hardware_path}"
    if ! observed_state_is_valid "${observed_temporary}"; then
        rm -f "${observed_temporary}"
        return 1
    fi
    if ! chmod 0644 "${observed_temporary}"; then
        rm -f "${observed_temporary}"
        return 1
    fi
    if ! mv -f "${observed_temporary}" "${output_path}"; then
        rm -f "${observed_temporary}"
        return 1
    fi
}
