mkdir -p /etc/systemd/system/symas-openldap-servers.service.d
cat <<EOF > /etc/systemd/system/symas-openldap-servers.service.d/override.conf
[Service]
LimitNOFILE=524288
EOF
systemctl daemon-reload

grep -q '^SLAPD_URLS=' /etc/default/symas-openldap \
  && sed -i 's|^SLAPD_URLS=.*|SLAPD_URLS="ldap:/// ldaps:/// ldapi:///"|' /etc/default/symas-openldap \
  || echo 'SLAPD_URLS="ldap:/// ldaps:/// ldapi:///"' >> /etc/default/symas-openldap

