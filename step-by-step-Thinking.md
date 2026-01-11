
Reading documents
Reading documents

Planning Docker Compose setup for OpenLDAP
The user wants to build an OpenLDAP setup with 2 masters, 2 read replicas, TLS, and various overlays. I'll suggest using Docker Compose with four OpenLDAP containers, plus two load balancers. For replication, osixia/openldap seems compatible with MirrorMode, supporting replication env variables. We'll mount custom configurations for slapd.conf and cn=config.

Preparing minimal templates and documentation
The user wants a step-by-step approach with minimal templates and instructions—using initial bootstrap scripts. I'll provide file structure, commands, and link to appropriate citations from reliable sources like the OpenLDAP Admin Guide, osixia/openldap docs, and HAProxy docs. For external links, I’ll ensure I use up-to-date references.

Building OpenLDAP Replica Set with Docker Compose
Crafting solution for OpenLDAP with Docker Compose
I’ll summarize the project architecture from the PDF and suggest a Docker Compose solution for two master nodes (MirrorMode) and two read replicas, with load balancers for read and write access. I’ll include prerequisites like Docker, Compose, and OpenSSL. I'll also provide folder structure, TLS cert gen, init LDIFs, and config updates. The final setup will rely on load balancers to enforce MirrorMode where only one node accepts writes.

Configuring HAProxy and read replicas
I’ll set up HAProxy to manage the write and read traffic: routing writes to master-a and failover to master-b, and round-robin for read requests spread across replicas and masters. For read-only replicas, I'll configure olcReadOnly: TRUE. For replication, I'll configure syncrepl and provide an example for delta-syncrepl.

Providing setup steps for replication and configuration
I'll propose using standard syncrepl for simplicity in setting up replication, with the option to enable delta-syncrepl later. The bootstrap script will configure overlays and replication after starting the containers. I'll include necessary commands with structured steps and provide citations and links as requested.

Designing folder structure and docker-compose YAML
I’ll define the folder structure and write the docker-compose YAML for the setup based on the PDF proposal, which includes 2 masters, 2 read replicas, and 2 load balancers. I'll add TLS, ppolicy, lastbind, and accesslog; also configure replication with MirrorMode. I'll carefully map ports to avoid privilege issues.

Configuring multi-master and replicas
For simplicity, I’ll opt for osixia’s built-in multi-master replication for masters, bypassing environment variables. Replicas will use the same image without replication, and I’ll configure them as syncrepl consumers using LDIFs. Using cn=config for authentication to manage the config DB works, so I’ll adjust that.

Configuring cn=config with domain and bootstrap LDIF
When using cn=config, I'll set the domain to something like dc=cae,dc=local but allow flexibility through variables. I'll create a bootstrap.ldif to add base entries into the data DIT. For cn=config modifications, there's a similar setup, so I’ll check the docs to verify.

Building Docker Compose LDAP Cluster with Replication
Designing LDAP setup with MirrorMode and LBs
Following the osixia docs, I’ll use their bootstrap structure. Need citations for OpenLDAP guides and relevant sources. Steps: 1. Clarify requirements like MirrorMode, replicas, LB endpoints, TLS. 2. Create folder. 3. Generate certs (or auto). Since we’re using pass-through, LDAP servers need their own certs. 4. Configure /etc/hosts, though service names resolve in Docker.

Considering TLS options for LDAP setup
To connect with ldaps://ldap-write:1636, I’m facing a TLS mismatch due to the backend server cert and the hostname. I could either terminate TLS at the LB with its own cert or use StartTLS, though both require matching hostnames. A potential solution could be using a cert with the SubjectAltName covering both ldap-master-a and ldap-write.

Deciding on certificate setup for backend servers
Since the certificate is on the backend and the LB is passing it through, to have a single endpoint, I need to ensure all backend servers share the same certificate. The cert should have a SAN covering all server names like ldap-write, ldap-master-a, etc. In the lab, I'll generate a wildcard or multi-SAN cert and mount it on all OpenLDAP containers as per the osixia docs.

Configuring load balancers for replication setup
For load balancing, I'm thinking of using haproxy. We'll set up ports 1389 for startTLS and 1636 for LDAPS. Since we'll use the same cert on all servers, pass-through should be fine. I'll route traffic to master-a primarily, with master-b as a backup. For writes, a separate VIP for modifications might be ideal. I'll also round-robin the replicas for reads and include masters for fallback. Replication will be configured in MirrorMode for masters.

Configuring OpenLDAP replication and overlays
I’ll enable syncprov overlay on the masters, configure accesslog and syncprov for delta-syncrepl. For replicas, we’ll use syncrepl from master-a and master-b. The configuration steps will include adding custom LDIFs for the Osixia setup. We'll also provide scripts like wait-for-ldap.sh and ensure unique serverIDs for each server. Replication will leverage the replicator user for bindDN and credentials. I'll also check schema modules for extras like ppolicy.

Thought for 2m 16s
Done

Sources
·
39
my_files
NXTEdge-CAETechnical Proposal OID migration to OpenLdap-V1 .pdf
openldap.org
OpenLDAP Software 2.4 Administrator's Guide: Replication
The following sections will describe the replication technology and discuss the various replication options that are available.Read more

kb.symas.com
Configure Delta-Syncrepl - Symas
11 Sept 2025 — Learn how to configure Delta-Syncrepl, a replication mechanism in LDAP, allowing you to synchronize changes between LDAP servers and ensuring data consistency.Read more
GitHub
GitHub - osixia/docker-openldap: OpenLDAP container image

port389.org
Testing HAProxy with 389 DS over LDAP/LDAPS
13 Jan 2024 — Testing HAProxy with 389 DS · Step 1: Create Virtual Machines · Step 2: Setup HAProxy Server with LDAPS or LDAP · Step 3: Configure 389 DS Client.Read more
github.com
osixia/docker-openldap
docker run --env LDAP_REPLICATION_HOSTS="#PYTHON2BASH:['ldap://ldap.example.org','ldap://ldap2.example.org']" --detach osixia/openldap:1.5.0. To convert yaml ...
github.com
Issue starting replication #160 - osixia/docker-openldap
2 Nov 2017 — Hello! I have a quick question on how to get replication started up using version 1.1.10. I have set the following environment variables:
github.com
georgemihalcea/ldapcheck: load balancer ldap check service
This is an example configuration for a haproxy with one ldap and one ldaps frontends (VIPs) and one ldap and one ldaps backends (server pools). In my example, ...Read more
github.com
Bugs affecting setting up LDAP replication · Issue #414
15 Apr 2020 — I'm trying to set up two containers with replication between them. The process is failing in a couple of places.
openldap.org
OpenLDAP Software 2.5 Administrator's Guide
8 May 2024 — This document describes how to build, configure, and operate OpenLDAP Software to provide directory services. This includes details on how ...Read more
openldap.org
7. Running slapd
This option specifies alternative listener configurations. The default is ldap:/// which implies LDAP over TCP on all interfaces on the default LDAP port 389.Read more

timatlee.com
Haproxy for Active Directory LDAPS | Tim's Blog
25 Nov 2021 — We've moved away from LDAP, so there's no reason to be proxying port 389. I wasn't able to start the container on port 636 without the net.Read more

wordpress.com
Configuring MMR using delta-syncrepl in OpenLDAP
23 Apr 2019 — First, this article will be covering configuration using the online cn=config configuration database for OpenLDAP as opposed to the old "slapd.Read more

ldapcon.org
OpenLDAP in High Availability Environments
by R Haferkamp · 2011 · Cited by 1 — As OpenLDAP is able to replicate its own configuration database (cn=config) via SyncRepl the example setup will make use of this feature. Even ...Read more
kow.is
Docker-compose an OpenLDAP server
31 Oct 2020 — Running OpenLDAP in a docker container makes things a whole lot simpler. I want to keep all my users and their passwords the same on every box.

reddit.com
Loadbalencing AC LDAPS with HAProxy : r/sysadmin
Hi everyone, I am right now trying to configure a loadbalencer for ldap and ldaps so we will be able to only configure 1 IP address in our ...

serverfault.com
Configuring openldap multimaster replication using cn= ...
1 Jul 2013 — This thread led me to the idea that the olcMirrorMode definition needs to be placed after the olcSyncrepl lines. I stopped the ldap servers ...Read more

serverfault.com
How to make AD highly available for applications that use it ...
27 Mar 2012 — LDAPS typically runs on port 636, and SSL/TLS encryption is involved. Here's how you can configure HAProxy for LDAPS load balancing: 1.Read more

redhat.com
9.2. OpenLDAP | System-Level Authentication Guide
The sync replication mode requires a specific configuration on both the provider and the consumers. This configuration is thoroughly described in the 18.3.1.Read more

docker.com
openLDAP Multi master replication in docker - General
23 Apr 2023 — Could anyone help please? Multi master replication. Quick example, with the default config. #Create the first ldap server, save the container id ...

docker.com
startcodex/openldap - Docker Image
This image is a fork of osixia/openldap with major updates: OpenLDAP 2.4 → 2.6: Only mdb backend supported (hdb/bdb removed); Base image: Debian Trixie ...

docker.com
osixia/openldap - Docker Image
This image is available on github, find help and source code here: https://github.com/osixia/docker-openldap⁠. Tag summary. Recent tags. develop-dev.

bidhankhatri.com.np
OpenLDAP MirrorMode Replication & MDB Backend in ...
21 Apr 2021 — In this tutorial, We will show MirrorMode replication between 2 CentOS 7 servers who's backend is mdb . We will also setup mdb backend for our OpenLDAP storage.Read more
pro-ldap.ru
Руководство администратора OpenLDAP 2.4: Репликация
Механизм репликации на основе LDAP Sync , коротко syncrepl , — это механизм репликации на стороне потребителя, позволяющий LDAP -серверу-потребителю ...Read more

igem.org
External Library / Docker Openldap
Environement variables defaults are set in image/env.yaml. You can modify environment variable values directly in this file and rebuild the image (see manual ...

stackoverflow.com
Haproxy ssl termination for LDAP
I would like to ask you for any kind of example that illustrates SSL termination for LDAP and Haproxy (636 on frontent and 389 on backend).Read more

stackoverflow.com
OpenLDAP olcMirrorMode
Mirrormode should be set up only on databases that you want to replicate, and the olcMirrorMode should be set after you've set up any and all syncrepl commands.Read more

tylersguides.com
HAProxy LDAP Backend - Tyler's Guides
31 May 2020 — A short guide with an example of an HAProxy LDAP Backend. Readers should be able to easily modify the example for their own use.

tylersguides.com
OpenLDAP Online Configuration Reference - Tyler's Guides
16 Mar 2019 — My OpenLDAP Online Configuration (OLC) Reference provides the OLC equivalents of the configuration file options.Read more

medium.com
openLDAP in mirror mode - Daniele Rugginenti - Medium
Needed for mirror mode dn: cn=module{0},cn=config changetype: modify add: olcModuleLoad olcModuleLoad: syncprov ## MIRROR MODE # Set up the ...Read more

medium.com
Setting up OpenLDAP and phpLDAPadmin with docker- ...
In this tutorial, I will explain how to set up an LDAP server and UI (phpLDAPadmin) using Docker and docker-compose.

scribd.com
OpenLDAP Admin Guide PDF
Replicating slapd Configuration (syncrepl and cn=config) ... For configuration, please see the MirrorMode section below. 18.2.4. Syncrepl Proxy Mode. While ...Read more

inha.fr
ldap-env.startup.yaml - agorha2-infra - GitLab - INHA
this file define environment variables used during the container **first start** in **startup files**. # This file is deleted right after startup files are ...

evolveum.com
OpenLDAP Replication
14 Feb 2022 — Add replication agreements on both masters, specifying the other master as provider. Use ldapmodify -Y EXTERNAL -H ldapi:/// to apply this configuration.Read more
zytrax.com
Chapter 6 LDAP Configuration
24 Mar 2023 — In a multi-master configuration olcMirrorMode/mirrormode TRUE must be present. In the case of slapd.conf this directive must appear AFTER ...Read more

ltb-project.org
Use HAProxy and OpenLDAP with proxy protocol
HAProxy is a famous TCP/HTTP proxy and balancer that can be used in front of OpenLDAP for high availability purpose.Read more

narkive.com
Troubleshooting synchronization
What is the difference between Mirror Mode and N-Way Multi-Master? Especially given that in N-Way Multi-Master, have to set olcMirrorMode to TRUE. 2. Given that ...Read more

perforce.com
Setting up HAProxy
Setting up HAProxy. HAProxy is a reliable, high performance TCP/HTTP Load Balancer that works nicely with Helix TeamHub High Availability deployment.Read more
openldap.com
Antw: RE: Syncrepl and mmr
>> >> Even in the Admin Guide is specifies setting it up that way...each >> server has all the others and itself listed. I was following the >> procedures