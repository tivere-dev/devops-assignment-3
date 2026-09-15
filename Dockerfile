# Lightweight image for the DevOps utility used in the CI pipeline.
# Alpine's BusyBox already provides ping, getent, df and timeout; bash (the
# interpreter) and iproute2 (for network details) are the only additions.
FROM alpine:3.20

RUN apk add --no-cache bash iproute2 \
    && addgroup -S app \
    && adduser -S -G app -h /app app

WORKDIR /app
COPY app/app.sh /app/app.sh

# Ensure the script is executable regardless of checkout permissions and
# verify it runs before the image is considered built.
RUN chmod 0755 /app/app.sh && /app/app.sh help >/dev/null

USER app

# The application is the entrypoint; the command name is the container argument:
#   docker run --rm devops-tool system-info
ENTRYPOINT ["/app/app.sh"]
CMD ["help"]
