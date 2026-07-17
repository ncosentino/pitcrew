# Babysitter image: a tiny Docker-CLI container that keeps a pool of truly-
# ephemeral runner containers filled (see manage-runners.sh). It only needs the
# docker client to talk to the host daemon via the mounted socket — it does NOT
# run dockerd itself (the runners are siblings on the host, not nested).
FROM docker:28-cli

RUN apk add --no-cache jq

COPY reconciliation.sh /usr/local/bin/reconciliation.sh
COPY manage-runners.sh /usr/local/bin/manage-runners.sh
RUN chmod +x /usr/local/bin/manage-runners.sh /usr/local/bin/reconciliation.sh

ENTRYPOINT ["/usr/local/bin/manage-runners.sh"]
