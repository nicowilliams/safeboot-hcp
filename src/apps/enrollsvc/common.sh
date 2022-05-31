# This file (common.sh) contains definitions required within the git container
# for operating on the repository, e.g. dropping privs to the db_user or
# flask_user, taking and releasing the lockfile, etc. The conventions for the
# repository's directory layout and the file contents are put in a seperate
# file, common_defs.sh, which is sourced by this file _and is actually
# committed to the repo itself_. This is so that common_def.s is replicated to
# the attestation service nodes, so that they make the same directory-layout
# (and semantic) assumptions.

. /hcp/common/hcp.sh

set -e

# A note about security. We priv-sep the flask app (that implements the URL
# handlers for the management interface) from the enrollment code
# (asset-generation and DB manipulation). We run them both as distinct,
# non-root accounts. The flask handlers invoke the enrollment functions via a
# curated sudo configuration. A critical requirement is that there be no way
# for the caller (flask) to be able to influence the environment of the callee
# (enrollment). As such, we want to avoid whitelisting and other
# environment-forwarding mechanisms, as they represent potential attack vectors
# (e.g. if a flask handler is compromised).
#
# We can't solve this by baking all configuration into the container image
# (/etc/environment), because we want general-purpose Enrollment Service images
# (not configuration-specific), and we want images to be built and deployed
# from behind a CI pipeline, not by prod hosts and operators.
#
# So, here's what we do;
# - "docker run" invocations always run, initially, as root within their
#   respective containers, before dropping privs to db_user (one-time init of
#   the database) or flask_user (to start the management interface). I.e. no
#   use of "--user", "sudo", or "su" in the "docker run" command-line.
# - We only ever drop privs, we never escalate to root.
# - Instance configuration is passed in as "--env" arguments to "docker run".
# - This common.sh file detects when it is running as root and will _write_
#   /etc/environment in that case.
# - All non-root environments pick up this uncontaminated /etc/environment;
#   - when we drop privs, and
#   - when a call is made across a sudo boundary.
# - No whitelisting or other environment carry-over.
#
# NB: because the user accounts (db_user and flask_user) are created by
# Dockerfile, those values _are_ baked into the container images and get
# propogated into the initial (root) environment by "ENV" commands in the
# Dockerfile. HCP_ENROLLSVC_STATE, on the other hand, is specified at "docker
# run" time. This file treats them all the same way, but it's worth knowing.

if [[ `whoami` != "root" ]]; then
	if [[ -z "$HCP_ENVIRONMENT_SET" ]]; then
		echo "Running in reduced non-root environment (sudo probably)." >&2
		cat /etc/environment >&2
		source /etc/environment
	fi
fi

if [[ -z "$HCP_VER" ]]; then
	echo "Error, HCP_VER must be set" >&2
fi
if [[ ! -d "/home/db_user" ]]; then
	echo "Error, 'db_user' account missing or misconfigured" >&2
	exit 1
fi
if [[ ! -d "/home/flask_user" ]]; then
	echo "Error, 'flask_user' account missing or misconfigured" >&2
	exit 1
fi

if [[ ! -d "/safeboot/sbin" ]]; then
	echo "Error, /safeboot/sbin is not present" >&2
	exit 1
fi
export PATH=$PATH:/safeboot/sbin
echo "Adding /safeboot/sbin to PATH" >&2

if [[ -d "/install/bin" ]]; then
	export PATH=$PATH:/install/bin
	echo "Adding /install/sbin to PATH" >&2
fi

if [[ -d "/install/lib" ]]; then
	export LD_LIBRARY_PATH=/install/lib:$LD_LIBRARY_PATH
	echo "Adding /install/lib to LD_LIBRARY_PATH" >&2
	if [[ -d /install/lib/python3/dist-packages ]]; then
		export PYTHONPATH=/install/lib/python3/dist-packages:$PYTHONPATH
		echo "Adding /install/lib/python3/dist-packages to PYTHONPATH" >&2
	fi
fi

if [[ `whoami` == "root" ]]; then
	# We're root, so we write the env-vars we got (from docker-run) to
	# /etc/environment so that non-root paths through common.sh source
	# those known-good values.
	touch /etc/environment
	chmod 644 /etc/environment
	echo "# HCP enrollsvc settings, put here so that non-root environments" >> /etc/environment
	echo "# always get known-good values, especially via sudo!" >> /etc/environment
	export_hcp_env >> /etc/environment
	echo "export HCP_ENVIRONMENT_SET=1" >> /etc/environment
fi

# Derive more configuration using these constants
REPO_NAME=enrolldb.git
EK_BASENAME=ekpubhash
REPO_PATH=$HCP_ENROLLSVC_STATE/$REPO_NAME
EK_PATH=$REPO_PATH/$EK_BASENAME
REPO_LOCKPATH=$HCP_ENROLLSVC_STATE/lock-$REPO_NAME

# Basic functions

function expect_root {
	if [[ `whoami` != "root" ]]; then
		echo "Error, running as \"`whoami`\" rather than \"root\"" >&2
		exit 1
	fi
}

function expect_db_user {
	if [[ `whoami` != "db_user" ]]; then
		echo "Error, running as \"`whoami`\" rather than \"db_user\"" >&2
		exit 1
	fi
}

function expect_flask_user {
	if [[ `whoami` != "flask_user" ]]; then
		echo "Error, running as \"`whoami`\" rather than \"flask_user\"" >&2
		exit 1
	fi
}

function drop_privs_db {
	# The only thing we need to whitelist is DB_IN_SETUP, which is used by
	# setup_enrolldb.sh to suppress common_defs.sh's test for an existing
	# db. We could've written this to /etc/environment too, but this case
	# only applies during one-time initialization whereas the other
	# settings apply longer term. (The fact this is only used as we drop
	# from root to non-root also means it's OK.)
	exec su --whitelist-environment DB_IN_SETUP -c "$*" - db_user
}

function drop_privs_flask {
	exec su -c "$*" - flask_user
}

function repo_cmd_lock {
	[[ -f $REPO_LOCKPATH ]] && echo "Warning, lockfile contention" >&2
	lockfile -1 -r 5 -l 30 -s 5 $REPO_LOCKPATH
}

function repo_cmd_unlock {
	rm -f $REPO_LOCKPATH
}

# The remaining functions are in a separate file because they form part of the git
# repo itself. (So that the attestation servers, which clone and use the repo
# in a read-only capacity, always use the same assumptions.) But to avoid
# chicken and eggs, we source the original (in the root directory, put there by
# Dockerfile) rather than the copy in the repo.

. /hcp/enrollsvc/common_defs.sh

# Except ... we also provide a reverse-lookup (hostname to ekpubhash) in a
# single file that the attestation service itself isn't supposed to need. We
# put the relevant definitions here (rather than in common_defs.h) to emphasize
# this point.
#
# TODO: we could do much better than the following. As the size of the dataset
# grows, the adds and deletes to the reverse-lookup table will dominate, as
# will memory and file-system thrashing (due to the need to copy and filter
# copies of the table inside the critical section). As with elsewhere, we make
# do with a simple but easy-to-validate solution for now, and mark this for a
# smarter implementation when there is enough time and focus to not make a mess
# of it (and once things are running at a scale that can detect problems).
#
# Each line of this file is a space-separated 2-tuple of;
# - the reversed hostname (per 'rev')
# - the ekpubhash (truncated to 32 characters if appropriate, i.e. to match the
#   name of the per-TPM sub-sub-sub-drectory in the ekpubhash/ directory tree).

# The initially-empty file
HN2EK_BASENAME=hn2ek
HN2EK_PATH=$REPO_PATH/$HN2EK_BASENAME
