# script 
ip a
ssh root@ip
password is root

node 1 192.168.64.5/24

ssh root@192.168.64.5 "rm -rf /root/script"
scp -r ./script root@192.168.64.5:/root/
ssh root@192.168.64.5 "chmod +x -R /root/script"

ssh root@192.168.64.5
mkdir script

cd ..
cd script
chmod +x install-symas-openldap-all-in-one.sh
sudo ./install-symas-openldap-all-in-one.sh

systemctl stop slapd || systemctl stop symas-openldap-servers

vi /opt/symas/etc/openldap/slapd.d/cn=config/olcDatabase={0}config.ldif

olcAccess: {0}to * by dn.exact=gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth manage by * none

systemctl start slapd || systemctl start symas-openldap-servers


slappasswd
TheN1le1
Yh;1+49iY6)?

# copy the hash, then:
sudo /opt/symas/bin/ldapmodify -Y EXTERNAL -H ldapi:/// <<'EOF'
dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcRootPW
olcRootPW: {SSHA}0jKfMAZNjO+3/HOSvTk/c3tRHl/DHvsJ
EOF


ldapsearch -Y EXTERNAL -H ldapi:/// \
  -b 'olcDatabase={0}config,cn=config' -LLL olcAccess