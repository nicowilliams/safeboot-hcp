#!/bin/bash

source /hcp/common/hcp.sh

if [[ -z $HCP_SSHSVC_STATE ]]; then
	echo "Error, 'HCP_SSHSVC_STATE' not defined" >&2
	exit 1
fi
if [[ ! -d $HCP_SSHSVC_STATE ]]; then
	echo "Error, '$HCP_SSHSVC_STATE' (HCP_SSHSVC_STATE) doesn't exist" >&2
	exit 1
fi

# We rely on the backgrounded attester to perform attestation and install the
# received assets. We will proceed once this has happened at least once.
# Handle initialization ordering issues by retrying.
waitcount=0
until [[ -f $HCP_ATTESTER_TOUCHFILE ]]; do
	waitcount=$((waitcount+1))
	if [[ $waitcount -eq 1 ]]; then
		echo "Warning: waiting for attestation" >&2
	fi
	if [[ $waitcount -eq 11 ]]; then
		echo "Warning: waited for another 10 seconds" >&2
		waitcount=1
	fi
	sleep 1
done

# Create some expected accounts
role_account_uid_file user1 $HCP_SSHSVC_STATE/uid-user1 "Test User 1,,,,"
role_account_uid_file user2 $HCP_SSHSVC_STATE/uid-user2 "Test User 2,,,,"
role_account_uid_file user3 $HCP_SSHSVC_STATE/uid-user3 "Test User 3,,,,"
role_account_uid_file alicia $HCP_SSHSVC_STATE/uid-alicia "Alicia Not-Alice,,,,"

# sshd expects this directory to exist
mkdir -p /run/sshd
chmod 755 /run/sshd

# and we want sshd to use these settings;
if [[ ! -f /etc/ssh/sshd_config.d/hcp_ssh_svc.conf ]]; then
	cat > /etc/ssh/sshd_config.d/hcp_ssh_svc.conf <<EOF
# Auto-generated by run_sshsvc.sh
# We need to enable GSSAPI authn to use Kerberos
GSSAPIAuthentication yes
GSSAPICleanupCredentials yes
EOF
fi

# -e tells it to log to stderr, -D tells it not to detach and become a daemon.
/usr/sbin/sshd -e -D
