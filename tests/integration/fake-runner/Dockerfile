FROM alpine:3.22

COPY fake-runner.sh /usr/local/bin/fake-runner.sh
RUN chmod +x /usr/local/bin/fake-runner.sh

ENTRYPOINT ["/usr/local/bin/fake-runner.sh"]
