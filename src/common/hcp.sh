#!/bin/bash

# For interactive shells, don't "set -e", it can be (more than) mildly
# inconvenient to have the shell exit every time you run a command that exits
# with a non-zero status code. It's good discipline for scripts though.
[[ -z $PS1 ]] && set -e

# Always call log(), it'll decide whether to print or not
log() {
	if [[ -n $VERBOSE ]]; then
		echo -E "$1" >&2
	fi
}

function add_env_path {
	if [[ -n $1 ]]; then
		echo "$1:$2"
	else
		echo "$2"
	fi
}

function add_install_path {
	local D=$1
	if [[ ! -d $D ]]; then return; fi
	if [[ -d "$D/bin" ]]; then
		export PATH=$(add_env_path "$PATH" "$D/bin")
	fi
	if [[ -d "$D/sbin" ]]; then
		export PATH=$(add_env_path "$PATH" "$D/sbin")
	fi
	if [[ -d "$D/libexec" ]]; then
		export PATH=$(add_env_path "$PATH" "$D/libexec")
	fi
	if [[ -d "$D/lib" ]]; then
		export LD_LIBRARY_PATH=$(add_env_path \
			"$LD_LIBRARY_PATH" "$D/lib")
		if [[ -d "$D/lib/python/dist-packages" ]]; then
			export PYTHONPATH=$(add_env_path \
				"$PYTHONPATH" "$D/lib/python/dist-packages")
		fi
	fi

}

for i in $(find / -maxdepth 1 -mindepth 1 -type d -name "install-*"); do
	add_install_path "$i"
done

function source_safeboot_functions {
	if [[ ! -f /install-safeboot/functions.sh ]]; then
		echo "Error, Safeboot 'functions.sh' isn't installed"
		return 1
	fi
	source "/install-safeboot/functions.sh"
}

function show_hcp_env {
	printenv | egrep -e "^HCP_" | sort
}

function export_hcp_env {
	printenv | egrep -e "^HCP_" | sort | sed -e "s/^HCP_/export HCP_/" |
		sed -e "s/\"/\\\"/" | sed -e "s/=/=\"/" | sed -e "s/$/\"/"
}

# Load instance-specific environment settings based on the HCP_INSTANCE
# environment variable. Ie. when starting the container, if HCP_INSTANCE is set
# then we source the file it points to (and if there is a common.env in the
# same directory, we source that too).
if [[ -n $HCP_INSTANCE ]]; then
	log "HCP: processing HCP_INSTANCE=$HCP_INSTANCE"
	if [[ ! -f $HCP_INSTANCE ]]; then
		echo "Error, $HCP_INSTANCE not found" >&2
		return 1
	fi
	HCP_LAUNCH_DIR=$(dirname "$HCP_INSTANCE")
	HCP_LAUNCH_ENV=$(basename "$HCP_INSTANCE")
	if [[ -f "$HCP_LAUNCH_DIR/common.env" ]]; then
		log "HCP: source common.env"
		source "$HCP_LAUNCH_DIR/common.env"
	fi
	log "HCP: source $HCP_LAUNCH_ENV"
	source "$HCP_LAUNCH_DIR/$HCP_LAUNCH_ENV"
else
	log "HCP: no HCP_INSTANCE"
fi

# The following is flexible support for (re)creating a role account with an
# associated UID file, which is typically in persistent storage. It generalises
# to cases with a single container or multiple distinct containers, using the
# same persistent storage, that need to have an agreed-upon account and UID.
# When the UID file hasn't yet been created, the first caller will create the
# account with a dynamically assigned UID, then print that into the UID file,
# so that subsequent callers (if in distinct containers) can create the same
# account with the same UID. If a container restarts and no longer has the
# account locally, it will do likewise - recreate the account with the UID from
# the UID file.
# NB: because of adduser's semantics, this function doesn't like to race
# against multiple calls of itself. (Collisions and conflicts on creation of
# groups, etc.) So we use a very crude mutex, based on 'mkdir'.
#  $1 - name of the role account
#  $2 - path to the UID file
#  $3 - gecos/finger string for the account
function role_account_uid_file {
	retries=0
	until mkdir /var/lock/hcp_uid_creation; do
		retries=$((retries+1))
		if [[ $retries -eq 5 ]]; then
			echo "Warning, lock contention on role-account creation" >&2
			retries=0
		fi
		sleep 1
	done
	retval=0
	internal_role_account_uid_file "$1" "$2" "$3" || retval=$?
	rmdir /var/lock/hcp_uid_creation
	return $retval
}
function internal_role_account_uid_file {
	if [[ ! -f $2 ]]; then
		if ! egrep "^$1:" /etc/passwd; then
			err_adduser=$(mktemp)
			echo "Creating '$1' role account" >&2
			if ! adduser --disabled-password --quiet \
					--gecos "$3" $1 > $err_adduser 2>&1 ; then
				echo "Error, couldn't create '$1'" >&2
				cat $err_adduser >&2
				rm $err_adduser
				exit 1
			fi
			rm $err_adduser
		fi
		echo "Generating '$1' UID file ($2)"
		touch $2
		chown $1 $2
	else
		ENROLLSVC_UID_FLASK=$(stat -c '%u' $2)
		if ! egrep "^$1:" /etc/passwd; then
			echo "Recreating '$1' role account with UID=$ENROLLSVC_UID_FLASK" >&2
			if ! adduser --disabled-password --quiet \
					--uid $ENROLLSVC_UID_FLASK \
					--gecos "$3" $1 > /dev/null 2>&1 ; then
				echo "Error, couldn't recreate '$1'" >&2
				exit 1
			fi
		fi
	fi
}

# Utility for adding a PEM file to the set of trust roots for the system. This
# can be called multiple times to update (if changed) the same trust roots, eg.
# when used inside an attestation-completion callback. As such, $2 and $3
# specify a CA-store subdirectory and filename (respectively) to use for the
# PEM file being added. If the same $2 and $3 arguments are provided later on,
# it is assumed to be an update to the same trust roots.
# $1 = file containing the trust roots
# $2 = CA-store subdirectory (can be multiple layers deep)
# $3 = CA-store filename
function add_trust_root {
	if [[ ! -f $1 ]]; then
		echo "Error, no '$1' found" >&2
		return 1
	fi
	echo "Adding '$1' as a trust root"
	if [[ -f "/usr/share/ca-certificates/$2/$3" ]]; then
		if cmp "$1" "/usr/share/ca-certificates/$2/$3"; then
			echo "  - already exists and hasn't changed, skipping"
			return 0
		fi
		echo "  - exists but has changd, overriding"
		cp "$1" "/usr/share/ca-certificates/$2/$3"
		update-ca-certificates
	else
		echo "  - no prior trust root, installing"
		mkdir -p "/usr/share/ca-certificates/$2"
		cp "$1" "/usr/share/ca-certificates/$2/$3"
		echo "$2/$3" >> /etc/ca-certificates.conf
		update-ca-certificates
	fi
}

# The hcp_common.py function 'dict_timedelta' parses a time period out of a
# JSON struct so that it can be expressed using any of 'years', 'months',
# 'weeks', 'days', 'hours', 'minutes', and/or 'seconds'. This bash version is
# similar except;
# - it takes the JSON string in $1, whereas the python version takes a python
#   dict (already converted from JSON),
# - it returns an integer number of seconds, whereas the python version
#   returns a datetime.timedelta object.
function dict_timedelta {
	thejson=$1
	# for get_element;
	#  $1 = name
	function get_element {
		x=$(echo "$thejson" | jq -r ".$1 // 0")
		echo "$x"
	}
	val=0
	val=$((val + $(get_element "years") * 365 * 24 * 60 * 60))
	val=$((val + $(get_element "months") * 28 * 24 * 60 * 60))
	val=$((val + $(get_element "weeks") * 7 * 24 * 60 * 60))
	val=$((val + $(get_element "days") * 24 * 60 * 60))
	val=$((val + $(get_element "hours") * 60 * 60))
	val=$((val + $(get_element "minutes") * 60))
	val=$((val + $(get_element "seconds")))
	echo "$val"
}
