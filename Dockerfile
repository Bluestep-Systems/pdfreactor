FROM realobjects/pdfreactor:12.1.0
LABEL org.opencontainers.image.source=https://github.com/Bluestep-Systems/pdfreactor
LABEL org.opencontainers.image.description="PDF Reactor throttled"

HEALTHCHECK NONE

USER root
RUN microdnf install -y util-linux && microdnf clean all

USER pdfreactor
ENV CORES="0-3"
ENTRYPOINT ["/entrypoint.sh"]

COPY entrypoint.sh /entrypoint.sh
