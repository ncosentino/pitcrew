ARG RUNNER_IMAGE
ARG DOCKER_ANDROID_IMAGE

FROM ${RUNNER_IMAGE} AS runner

FROM ${DOCKER_ANDROID_IMAGE}

USER root

RUN apt-get -qqy update \
 && apt-get -qqy install --no-install-recommends curl dumb-init git gosu jq openssl \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

COPY --from=runner /actions-runner /actions-runner
COPY --from=runner /entrypoint.sh /token.sh /app_token.sh /
COPY start-android-emulator /usr/local/bin/start-android-emulator

RUN chmod 0755 \
      /entrypoint.sh \
      /token.sh \
      /app_token.sh \
      /usr/local/bin/start-android-emulator \
 && mkdir -p /_work /opt/hostedtoolcache \
 && /actions-runner/bin/Runner.Listener --version

ENV AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache \
    APPIUM=false \
    USER_BEHAVIOR_ANALYTICS=false \
    WEB_LOG=false \
    WEB_VNC=false

WORKDIR /actions-runner

ENTRYPOINT ["/entrypoint.sh"]
CMD ["./bin/Runner.Listener", "run", "--startuptype", "service"]
