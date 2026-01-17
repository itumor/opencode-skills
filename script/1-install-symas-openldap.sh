wget -q https://repo.symas.com/configs/SOLDAP/rhel9/release26.repo -O /etc/yum.repos.d/soldap-release26.repo
dnf clean all && dnf update -y
dnf update -y
dnf -y install symas-openldap-clients symas-openldap-servers
