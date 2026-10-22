# Sample web application: static content on unprivileged NGINX (UID 101, port 8080).
# The base image is pinned by digest; Renovate proposes updates.
FROM nginxinc/nginx-unprivileged:1.30.4-alpine@sha256:adf5042a17f4ecdd200c595fa9ffd1be37efb18f89a830bd1a00e4ab4d59d42c

COPY --chown=101:101 nginx.conf /etc/nginx/conf.d/default.conf
COPY --chown=101:101 site/ /usr/share/nginx/html/

USER 101
EXPOSE 8080
