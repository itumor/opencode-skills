systemctl start slapd
systemctl start symas-openldap-servers
systemctl enable symas-openldap-servers
systemctl restart slapd
systemctl restart symas-openldap-servers