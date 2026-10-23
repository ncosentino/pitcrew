FROM --platform=linux/amd64 docker:28.5.2-dind@sha256:2a232a42256f70d78e3cc5d2b5d6b3276710a0de0596c145f627ecfae90282ac AS engine
FROM --platform=linux/amd64 mcr.microsoft.com/dotnet/sdk:10.0.302@sha256:72dd743782f2ae7e5476fd64f6a460045e3998dc862218b80e6944cba79a01b0
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends iptables iproute2 procps \
    && rm -rf /var/lib/apt/lists/*
COPY --from=engine /usr/local/bin/docker /usr/local/bin/dockerd /usr/local/bin/containerd /usr/local/bin/containerd-shim-runc-v2 /usr/local/bin/runc /usr/local/bin/docker-init /usr/local/bin/docker-proxy /usr/local/bin/
WORKDIR /qualification
COPY NestedDockerSmoke.csproj Program.cs ./source/
RUN test "$(dotnet --version)" = 10.0.302 \
    && test "$(docker --version | cut -d' ' -f3 | tr -d ',')" = 28.5.2 \
    && dotnet publish source/NestedDockerSmoke.csproj --configuration Release --output /qualification/bin \
    && rm -rf source
COPY runner.sh /actions-runner/bin/Runner.Listener
RUN chmod 0755 /actions-runner/bin/Runner.Listener
