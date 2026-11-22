# The KubeFactory server as a container: the game's Linux build, run headless
# in server mode (docs/SERVER.md), with kf-agent for kubeconfig sources and the
# Docker CLI for Docker sources. kf-host (docs/HOST_SERVICE.md) keeps it running.
#
# Build it with tools/build-server-image.ps1 (or .sh), which exports the game
# and kf-agent for Linux into the build folder first.
#
# It holds no credential. A kubeconfig or the Docker socket reaches it only as a
# mount the admin chose in host.json.
FROM docker:27.5.1-cli AS cli

FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates libfontconfig1 \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --create-home --uid 10001 kubefactory \
 && mkdir /data && chown kubefactory /data
COPY --from=cli /usr/local/bin/docker /usr/local/bin/docker
COPY --chmod=755 KubeFactory.x86_64 kf-agent /opt/kubefactory/
ENV KF_SERVER_DIR=/data
USER kubefactory
WORKDIR /home/kubefactory
EXPOSE 7666
LABEL org.opencontainers.image.title="KubeFactory server" \
      org.opencontainers.image.source="https://github.com/DasCondor/kubefactory" \
      org.opencontainers.image.licenses="MIT"
ENTRYPOINT ["/opt/kubefactory/KubeFactory.x86_64", "--headless", "--"]
CMD ["--server=7666", "--listen=0.0.0.0", "--demo"]
