#!/bin/bash

source /hcp/common/hcp.sh

if [[ -z $HCP_KDC_STATE ]]; then
	echo "Error, 'HCP_KDC_STATE' not defined" >&2
	exit 1
fi
if [[ ! -d $HCP_KDC_STATE ]]; then
	echo "Error, '$HCP_KDC_STATE' (HCP_KDC_STATE) doesn't exist" >&2
	exit 1
fi

# Run the attestation and get our assets
# Note, run_client is not a service, it's a utility, so it doesn't retry
# forever waiting for things to be ready to succeed. We, on the other hand,
# _are_ a service, so we need to be more forgiving.
attestlog=$(mktemp)
if ! /hcp/tools/run_client.sh 2> $attestlog; then
	echo "Warning: the attestation client lost patience, error output follows;" >&2
	cat $attestlog >&2
	rm $attestlog
	echo "Warning: suppressing error output from future attestation attempts" >&2
	attestation_done=
	until [[ -n $attestation_done ]]; do
		echo "Warning: waiting 10 seconds before retrying attestation" >&2
		sleep 10
		echo "Retrying attestation" >&2
		/hcp/tools/run_client.sh 2> /dev/null && attestation_done=yes
	done
fi

if [[ ! -x $(which kdc) ]]; then
	echo "Error, no 'kdc' binary found"
	exit 1
fi

if [[ ! -x $(which ipropd-master) ]]; then
	echo "Error, no 'ipropd-master' binary found"
	exit 1
fi

if [[ ! -x $(which ipropd-slave) ]]; then
	echo "Error, no 'ipropd-slave' binary found"
	exit 1
fi

echo "Starting 'kdcsvc': $HCP_HOSTNAME"
echo "       REALM: $HCP_KDC_REALM"
echo "   NAMESPACE: $HCP_KDC_NAMESPACE"
echo "        MODE: $HCP_KDC_MODE"
echo "       STATE: $HCP_KDC_STATE"

# Handle first-time init of persistent state
if [[ ! -f $HCP_KDC_STATE/initialized ]]; then

	echo "Initializing KDC state"
	if [[ -z $HCP_KDC_REALM ]]; then
		echo "Error, HCP_KDC_REALM isn't set" >&2
		exit 1
	fi
	mkdir $HCP_KDC_STATE/etc
	mkdir $HCP_KDC_STATE/var

	# Produce kdc.conf
	echo "Creating $HCP_KDC_STATE/etc/kdc.conf"
	cat > $HCP_KDC_STATE/etc/kdc.conf << EOF
# Autogenerated from run_kdc.sh
[kdc]
	database = {
		dbname = $HCP_KDC_STATE/var/heimdal
		realm = $HCP_KDC_REALM
		log_file = $HCP_KDC_STATE/var/kdc.log
	}
	signal_socket = $HCP_KDC_STATE/var/signalsock-iprop
	iprop-acl = $HCP_KDC_STATE/etc/iprop-secondaries
	enable-pkinit = yes
	synthetic_clients = true
	pkinit_identity = FILE:/etc/ssl/hostcerts/hostcert-pkinit-kdc-key.pem
	pkinit_anchors = FILE:/usr/share/ca-certificates/HCP/certissuer.pem
	#pkinit_pool = PKCS12:/path/to/useful-intermediate-certs.pfx
	#pkinit_pool = FILE:/path/to/other-useful-intermediate-certs.pem
	pkinit_allow_proxy_certificate = no
	pkinit_win2k_require_binding = yes
	pkinit_principal_in_certificate = yes
[hdb]
	db-dir = $HCP_KDC_STATE/var
	enable_virtual_hostbased_princs = true
	virtual_hostbased_princ_mindots = 1
	virtual_hostbased_princ_maxdots = 5
EOF
	cat /etc/krb5.conf >> $HCP_KDC_STATE/etc/kdc.conf

	echo "Creating $HCP_KDC_STATE/etc/sudoers"
	cat > $HCP_KDC_STATE/etc/sudoers << EOF
# sudo rules for kdcsvc-mgmt > /etc/sudoers.d/hcp
Cmnd_Alias HCP = /hcp/kdcsvc/do_kadmin.sh
Defaults !lecture
Defaults !authenticate
www-data ALL = (root) HCP
EOF

	if [[ $HCP_KDC_MODE == "primary" ]]; then
		# Produce slaves
		echo "Creating $HCP_KDC_STATE/etc/iprop-secondaries"
		echo "# Generated by run_kdc.sh" > $HCP_KDC_STATE/etc/iprop-secondaries
		for i in $HCP_KDC_SECONDARIES; do
			echo "iprop/$i.$HCP_FQDN_DEFAULT_DOMAIN@$HCP_KDC_REALM" >> $HCP_KDC_STATE/etc/iprop-secondaries
		done
		# Produce script.kadmin
		echo "Creating $HCP_KDC_STATE/etc/script.kadmin"
		cat > $HCP_KDC_STATE/etc/script.kadmin << EOF
init --realm-max-ticket-life=unlimited --realm-max-renewable-life=unlimited $HCP_KDC_REALM
add_ns --key-rotation-epoch=-10d --key-rotation-period=5d --max-ticket-life=1d --max-renewable-life=5d --attributes= _/$HCP_KDC_NAMESPACE@$HCP_KDC_REALM
add_ns --key-rotation-epoch=-10d --key-rotation-period=5d --max-ticket-life=1d --max-renewable-life=5d --attributes=ok-as-delegate host/$HCP_KDC_NAMESPACE@$HCP_KDC_REALM
EOF

		echo "Initializing KDC via 'kadmin -l'"
		kadmin --config-file=$HCP_KDC_STATE/etc/kdc.conf -l < $HCP_KDC_STATE/etc/script.kadmin
	fi

	touch $HCP_KDC_STATE/initialized
fi

# Steps that may need to run on each container launch (not just first-time
# initialization)
if ! ln -s "$HCP_KDC_STATE/etc/sudoers" /etc/sudoers.d/hcp > /dev/null 2>&1 && \
		[[ ! -h /etc/sudoers.d/hcp ]]; then
	echo "Error, couldn't create symlink '/etc/sudoers.d/hcp'" >&2
	exit 1
fi
if [[ $HCP_KDC_STATE != /kdc ]] &&
		! ln -s "$HCP_KDC_STATE" /kdc > /dev/null 2>&1; then
	echo "Error, couldn't ensure /kdc exists" >&2
	exit 1
fi
# When a web handler (in mgmt_api.py, running as "www-data") runs 'sudo
# do_kadmin', we inhibit any transfer of environment through the sudo barrier
# as we want to protect against a compromised web app. So run_kdc.sh stores the
# environment at startup time, so that do_kadmin has a known-good source.
export_hcp_env > /root/exported.hcp.env
echo "export PATH=$PATH" >> /root/exported.hcp.env
echo "export LD_LIBRARY_PATH=$LD_LIBRARY_PATH" >> /root/exported.hcp.env

# Start the service. But which kind are we? :-)
#
# A primary KDC consists of;
# - "sub_kdc", with KDC_MODE=primary
#   - an authoritative/writable Kerberos database
#   - the 'kdc' service, whose only (direct) clients are other KDCs.
# - "primary_iprop"
#   - the replication service ('ipropd-master') that secondary KDCs pull from
#   - a restarter loop with logging of any failures
# - TODO: a web API that invokes "kadmin -l".
#
# A secondary KDC consists of;
# - "sub_kdc", with KDC_MODE=secondary
#   - a downstream/read-only mirror of the Kerberos database
#   - the 'kdc' service, used by any/all clients
# - "secondary_iprop"
#   - the replication client ('iprop_slave') that updates the mirror by pulling
#     from the primary KDC
#
# Defining HCP_NO_TRACE leaves stderr as pass-through, otherwise the default is
# that each element uses date-based "$HOME/debug-<tool>-<datetime>" log output
# (which in turn would typically be cleaned up by the "purger").
# Here, it's set for everyone's benefit, so everything jabbers to the console
# by default, and if you comment it out then everything goes to its own
# tracefile(s) instead. You can choose to set it selectively only when
# launching the components you want redirected. Eg. this lets container owners
# choose which of the sub-services they want on the container's stderr (and
# which they wish to ignore or handle by other means).
export HCP_NO_TRACE=1

# Primary and secondary fundamentally differ by which end of iprop they reside
# at. :-)
case $HCP_KDC_MODE in
primary)
	/hcp/kdcsvc/primary_iprop.py &
	;;
secondary)
	/hcp/kdcsvc/secondary_iprop.py &
	;;
*)
	echo "Error, HCP_KDC_MODE ($HCP_KDC_MODE) not recognized" >&2
	exit 1
	;;
esac

# Start the KDC
/hcp/kdcsvc/sub_kdc.py &

# Maybe start a HTTPS front-end
if [[ -n $HCP_KDC_ENABLE_NGINX ]]; then
	echo "kdcsvc::mgmt, running nginx as front-end proxy"
	# Copy the nginx config into place and start the service.
	cp "$HCP_KDC_NGINX_CONF" /etc/nginx/sites-enabled/
	nginx
fi

# this child will exec to uwsgi, so leave it as a child (don't exec)
/hcp/kdcsvc/launch_mgmt.sh
