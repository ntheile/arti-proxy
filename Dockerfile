FROM containers.torproject.org/tpo/onion-services/onimages/arti@sha256:852d7a334d99e00875924a0d33288e75a897ca2196bcd649c951b9a1158ac38b

USER root
RUN apk add --no-cache curl

COPY arti-healthcheck.sh /usr/local/bin/arti-healthcheck.sh
RUN chmod +x /usr/local/bin/arti-healthcheck.sh

ENV SOCKS_HOST=127.0.0.1
ENV SOCKS_PORT=9150
ENV HEALTHCHECK_URL=https://check.torproject.org/api/ip
ENV HEALTHCHECK_EXPECTED='"IsTor":true'
ENV HEALTHCHECK_MAX_TIME=30

HEALTHCHECK --interval=2m --timeout=35s --start-period=2m --retries=2 \
  CMD /usr/local/bin/arti-healthcheck.sh

USER arti
ENTRYPOINT ["arti"]
CMD ["proxy", "-o", "proxy.socks_listen=\"0.0.0.0:9150\"", "-o", "proxy.dns_listen=\"0.0.0.0:8853\""]
