# A Squid forward proxy on Alpine, running as the squid user.
FROM alpine:3.24.4
RUN apk add --no-cache squid \
 && mkdir -p /var/cache/squid /var/log/squid /run/squid \
 && chown -R squid:squid /var/cache/squid /var/log/squid /run/squid
COPY squid.conf /etc/squid/squid.conf
COPY allowlist.txt /etc/squid/allowlist.txt
EXPOSE 3128
USER squid
HEALTHCHECK --interval=3s --timeout=2s --retries=10 CMD squidclient -h 127.0.0.1 mgr:info >/dev/null 2>&1 || nc -z 127.0.0.1 3128
CMD ["squid", "-N", "-d", "1"]
