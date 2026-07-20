FROM alpine:3.22

# Optional baked-in one-shot job duration. The manager forwards only a fixed
# env allowlist to worker containers, so a job-simulating variant is produced by
# building with --build-arg JOB_SECONDS=<n> rather than a runtime env override.
ARG JOB_SECONDS=""
ENV FAKE_RUNNER_JOB_SECONDS=${JOB_SECONDS}

COPY fake-runner.sh /usr/local/bin/fake-runner.sh
RUN chmod +x /usr/local/bin/fake-runner.sh

ENTRYPOINT ["/usr/local/bin/fake-runner.sh"]
