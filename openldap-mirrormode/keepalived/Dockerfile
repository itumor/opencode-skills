FROM osixia/keepalived:2.0.20

ARG ROLE=master

# Bake the desired keepalived.conf into the image (the base image mutates the file at startup;
# bind-mounting a file here breaks because it can't be atomically replaced).
COPY keepalived-${ROLE}.conf /container/service/keepalived/assets/keepalived.conf
COPY check_slapd.sh /usr/local/bin/check_slapd.sh

RUN chmod +x /usr/local/bin/check_slapd.sh

