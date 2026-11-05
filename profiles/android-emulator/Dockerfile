ARG RUNNER_IMAGE=myoung34/github-runner:2.338.2-ubuntu-noble@sha256:23e3a4a1da30de5b462ad0ae13d901288e803a688075c3b9b5bb79b7148c07fa
ARG DOCKER_ANDROID_IMAGE=budtmo/docker-android:emulator_14.0_v3.6.0-p0@sha256:d0e1c84530702c1b1bcfb1b51b12bfd63b179932accab86d159fb870a994404b

FROM ${RUNNER_IMAGE} AS runner

FROM ${DOCKER_ANDROID_IMAGE}

USER root

RUN apt-get -qqy update \
 && apt-get -qqy install --no-install-recommends curl dumb-init git gosu jq libicu-dev openssl \
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
