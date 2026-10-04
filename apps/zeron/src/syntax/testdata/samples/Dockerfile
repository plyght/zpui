# syntax=docker/dockerfile:1
FROM alpine:3.19 AS build
ARG VERSION=1.0
ENV PATH="/app/bin:$PATH" LANG=C.UTF-8
WORKDIR /app
COPY --from=build --chown=app:app ./src /app/src
RUN apk add --no-cache curl && \
    echo "building $VERSION" > /tmp/log
RUN <<EOT
set -e
echo heredoc
EOT
COPY <<EOT /etc/config.json
{"key": "value", "n": 1}
EOT
EXPOSE 8080/tcp
HEALTHCHECK CMD curl -f http://localhost/ || exit 1
ENTRYPOINT ["/app/bin/zeron", "--serve"]
CMD ["--port", "8080"]
