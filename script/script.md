# script 
ip a
ssh root@ip


node 1 192.168.64.5/24

scp -r ./script root@192.168.64.5:/root/
ssh root@192.168.64.5
mkdir script
chmod +x -R script/
cd script
chmod +x install-symas-openldap-all-in-one.sh
sudo ./install-symas-openldap-all-in-one.sh
