#!/usr/bin/sh
#########################################################################
#
# Copyright (c) 2007-2021 Symas Corporation
# All rights reserved.
# 
# Redistribution and use in source and binary forms, with or without 
# modification, are permitted provided that the following conditions are 
# met:
# 
# * Redistributions of source code must retain the above copyright 
#   notice, this list of conditions and the following disclaimer.
# * Redistributions in binary form must reproduce the above 
#   copyright notice, this list of conditions and the following disclaimer 
#   in the documentation and/or other materials provided with the 
#   distribution.
# * Neither the name of the Symas Corporation nor the names of its 
#   contributors may be used to endorse or promote products derived from 
#   this software without specific prior written permission.
# 
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS 
# "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT 
# LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR 
# A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT 
# OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, 
# SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT 
# LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, 
# DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY 
# THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT 
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE 
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
# "portably" echo without a newline
pecho () {
	if [ "x$(echo -n foo\cbar)x" = "x-n foox" ]; then
		# ancient bourne shells only have \c
		echo $1\\c
	elif [ "x$(echo -n foo\\cbar)x" = "x-n foox" ]; then
		# some shells unquote differently
		echo $1\\c
	elif [ "x$(echo -n foo\cbar)x" = "xfoocbarx" ]; then
		# bash likes it csh style
		echo -n $1
	elif [ "x$(echo -n foo\\cbar)x" = "xfoocbarx" ]; then
		# some shells unquote differently
		echo -n $1
	else
		# ouch
		echo $1
	fi
}

# Must be root to run this script
if [ "$(id -ru)" -ne "0" ]; then
	echo "Because this script writes to directories that are owned by root,"
	echo "you must be root to run this script."
	exit 1
fi

#
# Set sane values for these variables. If you downloaded this script from 
# the Symas Forum or if you've moved either of these directories around
# you may need to set these to match your distribution.
BIN=/opt/symas/bin
SBIN=/opt/symas/sbin
LIB=/opt/symas/lib

if [ ! -x $LIB/slapd ]; then
	echo "Can't locate slapd executable. This script will exit."
	exit 1
fi

if [ ! -x $BIN/ldapsearch ]; then
	echo "Can't locate ldapsearch executable. This script will exit."
	exit 1
fi

STARTSERVER="systemctl start slapd"
STOPSERVER="systemctl stop slapd"

EXAMPLEDIR=/var/symas/openldap-data/example
SLAPD_CONF=/opt/symas/etc/openldap/slapd.conf
CONFIGDIR=/opt/symas/etc/openldap/slapd.d

SLAPD_GROUP=root

TESTSEARCH="$BIN/ldapsearch -x -H ldap://localhost:389/ -b cn=admin,dc=eab,dc=bank,dc=local -D dc=eab,dc=bank,dc=local -w secret"

cat <<EOF

                     *****  CONFIGURATION SELECTION *****

This script can either use the deprecated slapd.conf configuration file or
the cn=config configuration database.  Please choose:
1) slapd.conf
2) cn=config

EOF

pecho "Select 1 or 2, anything else to cancel: "
read config
if [ "$config" != "1" -a "$config" != "2" ]; then
  echo "Exiting.  No changes have been made to the system."
  exit 1
fi

if [ "$config" = "1" -a -d $CONFIGDIR ]; then
  echo "                     *****  WARNING *****"
  echo "Existing cn=config configuration directory present"
  echo "Enter YES to permanently ERASE this configuration."
  echo ""
  pecho "Type YES to continue, anything else to cancel: "
  read yn
  if [ "$yn" != "YES" ]; then
    exit 1
  else
    echo "Deleting contents of $CONFIGDIR..."
    rm -rf $CONFIGDIR
  fi
fi

if [ "$config" = "1" ]; then
  cat <<EOF


                     *****  WARNING *****

This script will set up an example database called dc=eab,dc=bank,dc=local
and configure Symas OpenLDAP to use this database.

In the process it will delete the contents of $EXAMPLEDIR
and replace the following file with an example version:
    $SLAPD_CONF

Any previously existing versions of these files will be lost!

EOF
fi

if [ "$config" = "2" ]; then
  cat <<EOF


                     *****  WARNING *****

This script will set up an example database called dc=eab,dc=bank,dc=local
and configure Symas OpenLDAP to use this database.

In the process it will delete the contents of $EXAMPLEDIR and $CONFIGDIR.

Any previously existing version of this file will be lost!

EOF
fi

pecho "Type YES to continue, anything else to cancel: "
read yn
if [ "$yn" != "YES" ]; then
	echo "Sample database creation has NOT taken place. No changes"
	echo "have been made to your system."
	exit 1
fi

$STOPSERVER

echo "Deleting contents of $EXAMPLEDIR..."
mkdir -p $EXAMPLEDIR 2>/dev/null
rm $EXAMPLEDIR/* 2>/dev/null

if [ "$config" = "2" ]; then
  echo "Deleting contents of $CONFIGDIR..."
  rm -rf $CONFIGDIR
  mkdir -p $CONFIGDIR
fi

if [ "$config" = "1" ]; then
    echo "Creating $SLAPD_CONF..."
    cat > $SLAPD_CONF <<EOF
#
# See slapd.conf(5) for details on configuration options.
# This file should NOT be world readable.
#
# Schema files. Note that not all of these schemas co-exist peacefully.
# Use only those you need and leave the rest commented out.
include     /opt/symas/etc/openldap/schema/core.schema
include     /opt/symas/etc/openldap/schema/cosine.schema
include     /opt/symas/etc/openldap/schema/inetorgperson.schema

# Files in which to store the process id and startup arguments.
# These files are needed by the init scripts, so only change
# these if you are prepared to edit those scripts as well.
pidfile         /var/symas/run/slapd.pid
argsfile        /var/symas/run/slapd.args

# Set the log level
loglevel stats sync

# Choose the directory for loadable modules.
modulepath  /opt/symas/lib/openldap

# Uncomment the moduleloads as needed to enable backend
# functionality.
# Load dynamic backend modules:
moduleload  back_mdb.la
moduleload  back_monitor.la

# Example access control policy:
#   Allow read access of root DSE
#   Allow self write access
#   Allow authenticated users read access
#   Allow anonymous users to authenticate
# Directives needed to implement policy:
access to dn="" by * read
access to *
    by self write
    by sockurl="^ldapi:///$" write
    by users read
    by anonymous auth
#
# if no access controls are present, the default policy is:
#   Allow read by all
#
# rootdn can always write!

#######################################################################
# Example mdb database definitions
#######################################################################
database    mdb
suffix      "dc=eab,dc=bank,dc=local"
rootdn      "cn=admin,dc=eab,dc=bank,dc=local"
# Cleartext passwords, especially for the rootdn, should
# be avoided. See slappasswd(8) and slapd.conf(5) for details describing
# the creation of encrypted passwords.
rootpw      {SSHA}MWDk53K4wiut5A9U361jzCp4Rr//iBmv

# Indices to maintain

# index default sets the basic type of indexing to perform if there isn't
# any indexing specified for a given attribute
index   default     eq
index   objectClass
index   cn

# The database directory MUST exist prior to running slapd AND
# should only be accessible by the slapd/tools. Mode 700 recommended.
# One directory will be needed for each backend, so you should
# create a subdirectory beneath /var/symas/openldap-data for each
# new backend. This is also where the DB_CONFIG file needs to be
# placed.
directory   /var/symas/openldap-data/example

# Here we specify the maximum on-disk size of the database. It is
# Recommended to set this near the expected free-space availability
# for the machine. This paramiter is not pre-allocated and simply
# represents the upward limit to which the database will be allowed
# to grow. Note: Specified in *bytes*. Here, we set it to 1gb.
maxsize 1073741824

#######################################################################
# Monitor database
#######################################################################
database    monitor
EOF
fi

if [ "$config" = "2" ]; then
  echo "Creating server configuration..."
  $SBIN/slapadd -q -n 0 -F $CONFIGDIR <<EOF
dn: cn=config
objectClass: olcGlobal
cn: config
olcLogLevel: Sync
olcLogLevel: Stats
olcPidFile: /var/symas/run/slapd.pid
olcArgsFile: /var/symas/run/slapd.args

dn: cn=schema,cn=config
objectClass: olcSchemaConfig
cn: schema

include: file:///opt/symas/etc/openldap/schema/core.ldif
include: file:///opt/symas/etc/openldap/schema/cosine.ldif
include: file:///opt/symas/etc/openldap/schema/inetorgperson.ldif

dn: cn=module{0},cn=config
objectClass: olcModuleList
cn: module{0}
olcModulePath: /opt/symas/lib/openldap
olcModuleLoad: {0}back_mdb.la
olcModuleLoad: {1}back_monitor.la

dn: olcDatabase={-1}frontend,cn=config
objectClass: olcDatabaseConfig
objectClass: olcFrontendConfig
olcDatabase: {-1}frontend
olcAccess: {0}to dn=""  by * read
olcAccess: {1}to *  by self write  by sockurl.exact="ldapi:///" write  by users read  by anonymous auth

dn: olcDatabase={0}config,cn=config
objectClass: olcDatabaseConfig
olcDatabase: {0}config
olcRootPW: {SSHA}MWDk53K4wiut5A9U361jzCp4Rr//iBmv
olcAccess: {0}to *  by * none

dn: olcDatabase={1}mdb,cn=config
objectClass: olcDatabaseConfig
objectClass: olcMdbConfig
olcDatabase: {1}mdb
olcSuffix: dc=eab,dc=bank,dc=local
olcRootDN: dc=eab,dc=bank,dc=local
olcRootPw: {SSHA}MWDk53K4wiut5A9U361jzCp4Rr//iBmv
olcDbDirectory: /var/symas/openldap-data/example
olcDbIndex: default eq
olcDbIndex: objectClass
olcDbIndex: cn
olcDbMaxSize: 1073741824

dn: olcDatabase={2}monitor,cn=config
objectClass: olcDatabaseConfig
olcDatabase: {2}monitor
olcRootDn: cn=config
olcMonitoring: FALSE
EOF

fi

echo "Creating the example database..."
$SBIN/slapadd -q <<EOF
dn: dc=eab,dc=bank,dc=local
objectClass: top
objectClass: organization
objectClass: dcObject
o: eab
dc: eab

EOF


echo $STARTSERVER
$STARTSERVER

echo "Waiting for slapd to complete its startup..."
sleep 10

echo "You can now perform a test search. During the search you can hit the"
echo "interrupt (ctrl-c) key to stop the search at any time."
pecho "Would you like to perform the test search now (y/n)? "
read t

if [ "$t" = "y" ]; then
	echo $TESTSEARCH
	eval $TESTSEARCH
else
	echo "You can run the test yourself any time by typing:"
	echo $TESTSEARCH
fi
