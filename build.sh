#!/usr/bin/env bash
#
# build.sh - entry point for automated Yocto build process
#
# Copyright (C) 2020  Alexandru N. Onea (onea.alex@gmail.com)
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation; either version 2 of the License, or (at your option) any later
# version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# this program; if not, write to the Free Software Foundation, Inc., 51 Franklin
# Street, Fifth Floor, Boston, MA  02110-1301, USA.
#

# identification of repo root directory and scripts base directory
declare -r SCRIPTDIR="$(realpath "$(dirname "$0")")"
declare -r ROOTDIR="$(realpath "$(dirname "${SCRIPTDIR}")")"

# project settings
declare -r project="rpi-learning-companion"
declare -r default_machine="raspberrypi4-64"

set -uo pipefail

# backup descriptors for use in interactive mode
exec 3>&1
exec 4>&2

. "${SCRIPTDIR}/lib/logger.sh"

run_cmd ()
{
	log_info "Running command \"$@\""
	eval "$@"
}

run_cmd_nolog ()
{
	eval "$@ &>/dev/null"
}

run_cmd_silent ()
{
	log_info "Running command \"$@\""
	eval "$@ &>/dev/null"
}

run_cmd_interactive ()
{
	log_info "Running command \"$@\""
	eval "$@ 1>&3 2>&4"
}

print_usage ()
{
cat<<HELP_TEXT 1>&3
build.sh - build intrastructure entry point for ${project}

Usage:
	build.sh [OPTIONS] [TARGET]

Available options:
	--bitbake-shell     interactive mode, provides a shell in the container
	--dry-run           run bitbake in dry run mode
	--continue          don't stop at first error, continue until the end
	--downloads PATH    set shared downloads location (default is ${hostdldir})
	--keep-container    don't remove the container after the build finished
	--cleanup-images    remove docker images associated with this project
	--qemu              generate qemu artifacts instead (enumation)
	--help              display this message

When running in non-interactive mode, TARGET can be used to indicate what
bitbake target to run. If none, the default target is ${bbtarget} and the
default machine is ${bbmachine:-not set}.
HELP_TEXT
}

# parse the command line and set globals
parse_cmdline ()
{
	declare -a params=()

	# store initial values in temporary copies
	local _bbshell="${bbshell}"
	local _bbdryrun="${bbdryrun}"
	local _bbmachine="${bbmachine}"
	local _bbcmd="${bbcmd}"
	local _bbinteractive="${bbinteractive}"
	local _bbcontinue="${bbcontinue}"
	local _bbkeepcontainer="${bbkeepcontainer}"
	local _hostdldir="${hostdldir}"

	while [ $# -ne 0 ]; do
		case "$1" in
			--help|-h)
				print_usage && exit 0
				;;
			--bitbake-shell)
				_bbshell="-it"
				_bbcmd="/bin/bash"
				_bbinteractive="_interactive"
				shift
				;;
			--dry-run|-n)
				_bbdryrun="-n"
				shift
				;;
			--continue|-k)
				_bbcontinue="-k"
				shift
				;;
			--qemu)
				_bbmachine="qemuarm64"
				shift
				;;
			--downloads)
				shift
				_hostdldir="$1"
				shift
				;;
			--cleanup-images)
				cleanup_docker_images
				exit $?
				;;
			--keep-container)
				_bbkeepcontainer=1
				shift
				;;
			--)
				shift
				break
				;;
			-*|--*)
				log_die "Unsupported flag \"$1\""
				;;
			*)
				params=("${params[@]}" "$1")
				shift
				;;
		esac
	done

	# set positional arguments in place
	set -- "${params[@]}" "$@"

	# validate host download directory
	hostdldir="$(realpath -- "${_hostdldir}" 2>/dev/null)"
	if [ -z "${hostdldir}" ] || \
		([ -e "${hostdldir}" ] && [ ! -d "${hostdldir}" ]); then
		log_die "Invalid downloads location \"${_hostdldir}\""
	fi

	# commit changes after cmdline parsing
	bbtarget="${1:-${bbtarget}}"
	bbshell="${_bbshell}"
	bbdryrun="${_bbdryrun}"
	bbcontinue="${_bbcontinue}"
	bbmachine="${_bbmachine}"
	bbcmd="${_bbcmd}"
	bbinteractive="${_bbinteractive}"
	bbkeepcontainer="${_bbkeepcontainer}"
}

check_user ()
{
	log_info "Checking user permissions"

	local owner_uid=$(id -u)
	local owner_gid=$(id -g)
	local owner_username=$(id -un)
	local owner_groupname=$(id -gn)

	if [ "${owner_uid}" == "0" ] || [ "${owner_gid}" == "0" ]; then
		log_die "You should not run this script as root!"
	fi

	log_info "Running the script as ${owner_username:-${owner_uid}}"
	log_info "UID: ${owner_uid} (${owner_username})"
	log_info "GID: ${owner_gid} (${owner_groupname})"
	log_info
}

check_prerequisites ()
{
	local prerequisites=("docker" "sha1sum" "git")
	local files=(
		"${SCRIPTDIR}/container.base"
		"${SCRIPTDIR}/packages.list"
		"${SCRIPTDIR}/docker/Dockerfile"
	)

	log_info "Checking prerequisites"
	for prog in "${prerequisites[@]}"; do
		log_info "Looking for utility ${prog}"
		if ! command -v ${prog} &>/dev/null; then
			log_die "${prog} is required but not available."
		fi
	done

	for file in "${files[@]}"; do
		log_info "Checking file $(basename "${file}")"
		[ -f "${file}" ] || log_die "${short_file} not found"
	done

	# create the host downloads directory to avoid later mount issues
	if [ -n "${hostdldir}" ] && [ ! -d "${hostdldir}" ]; then
		log_warn "Creating \"${hostdldir}\" to avoid bind mount issues"
		mkdir -p "${hostdldir}"

		if [ $? -ne 0 ]; then
			log_error "Unable to create download dir, will not mount!"
			mountdldir=
		fi
	fi

	# touch container bash history to avoid later mount issues
	if [ ! -f "${hostbash_history}" ]; then
		log_warn "Touching \"${hostbash_history}\" for container bash history"
		run_cmd_nolog touch "${hostbash_history}"

		if [ $? -ne 0 ]; then
			log_warn "Failed to touch \"${hostbash_history}\""
		fi
	fi

	# touch .netrc to avoid later mount issues
	if [ ! -f "${hostnetrc}" ]; then
		log_warn "Touching \"${hostnetrc}\" to avoid bind mount issues"
		run_cmd_nolog touch "${hostnetrc}"

		if [ $? -ne 0 ]; then
			log_warn "Failed to touch \"${hostnetrc}\""
		fi
	fi

	# create .ssh to avoid later mount issues
	if [ ! -d "${hostdotssh}" ]; then
		log_warn "Creating \"${hostdotssh}\" to avoid bind mount issues"
		run_cmd_nolog mkdir -p "${hostdotssh}"

		if [ $? -ne 0 ]; then
			log_warn "Failed to touch \"${hostdotssh}\""
		fi
	fi

	# create .subversion to avoid later mount issues
	if [ ! -d "${hostdotsvn}" ]; then
		log_warn "Creating \"${hostdotsvn}\" to avoid bind mount issues"
		run_cmd_nolog mkdir -p "${hostdotsvn}"

		if [ $? -ne 0 ]; then
			log_warn "Failed to touch \"${hostdotsvn}\""
		fi
	fi

	log_info "Prerequisites OK"
	log_info
}

check_project_revision ()
{
	local dirty=$(git diff --quiet || echo "-dirty")

	pushd "${ROOTDIR}" &>/dev/null

	log_info "Checking project revision"
	echo "$(git status -sb)"
	echo

	if [ -n "${dirty}" ]; then
		echo "$(git submodule foreach 'git status -sb; echo')"
		echo
	fi

	popd &>/dev/null

	log_info "HEAD revision: $(git rev-parse HEAD)${dirty}"
	log_info
}

# build a fresh docker image
# params:
#    $1 - tagname for the new image
build_docker_image ()
{
	local image_tag="$1"
	local image_base="$2"
	local extra_packages="$(tr '\n' ' ' <<<"$3")"

	declare -r timezone="$(cat /etc/timezone 2>/dev/null)"
	declare -r tz_area="${timezone%%/*}"
	declare -r tz_zone="${timezone#*/}"

	read -rd '' tz_data <<TZ_DATA
tzdata tzdata/Areas select ${tz_area:-Europe}
tzdata tzdata/Zones/${tz_area:-Europe} select ${tz_zone:-Bucharest}
TZ_DATA

	log_info "Building docker image ${image_tag} based on ${image_base}"
	log_info "Extra packages: ${extra_packages}"

	run_cmd docker image build \
		--iidfile "${SCRIPTDIR}/image_${project}.stamp" \
		--force-rm \
		--build-arg "\"BASELINE=${image_base}\"" \
		--build-arg "\"EXTRA_PACKAGES=${extra_packages}\"" \
		--build-arg "\"TZ_DATA=${tz_data}\"" \
		--file "${SCRIPTDIR}/docker/Dockerfile" \
		--tag "${image_tag}" \
		"${SCRIPTDIR}/docker"

	[ $? -eq 0 ] || log_die "Failed to create docker image"

	image_id=$(<"${SCRIPTDIR}/image_${project}.stamp")
	run_cmd_nolog rm "${SCRIPTDIR}/image_${project}.stamp"
}

cleanup_docker_images ()
{
	declare -a images=

	log_info "Cleaning up images for project \"${project}\""

	images=$(docker image ls -aqf "reference=${project}")
	if [ -z "${images}" ]; then
		log_info "No images found on this host"
		return
	fi

	log_info "Found ${#images[@]} images on this host: ${images[@]}"
	for image_id in "${images[@]}"; do
		log_info "Removing image ${image_id}"
		run_cmd_silent docker image rm "${image_id}"
		[ $? -eq 0 ] || log_warn "Failed to remove image ${image_id}"
	done
}

# removes previous docker containers
cleanup_docker_containers ()
{
	local old_containers=
	local owner=$(id -u)

	log_info "Cleaning up old containers"

	old_containers=($(docker container ls -aqf "name=${owner}-${project}-*"))

	# stop old container, if necessary, and remove container id files
	for container_id in "${old_containers[@]}"; do
		log_info "Stopping and removing container ${container_id}"
		run_cmd_nolog docker container stop ${container_id}
		run_cmd_nolog docker container rm -f ${container_id}
		[ $? -eq 0 ] || log_warn "Could not stop old container ${container_id}"
	done

	# remove remaining cid files, if any
	run_cmd_nolog rm -f "${SCRIPTDIR}/container_${project}.stamp"
}

# create a new docker container based on existing image
# params:
#    $1 - container hash
setup_docker_container ()
{
	local image_id=
	local container_id=
	local image_hash=

	cleanup_docker_containers
	fetch_docker_image

	image_hash=$(<"${SCRIPTDIR}/image_${project}.version")

	log_info "Creating container using image ${image_id}"

	run_cmd_silent docker container create \
		--cidfile "${SCRIPTDIR}/container_${project}.stamp" \
		--tty \
		--interactive \
		--volume "${hostsrcdir}:${bbsrc}" \
		--volume "${hostdldir}:${bbdldir}" \
		--volume "${hostbash_history}:${bbhome}/.bash_history" \
		--volume "${hostnetrc}:${bbhome}/.netrc" \
		--volume "${hostdotssh}:${bbhome}/.ssh" \
		--volume "${hostdotsvn}:${bbhome}/.subversion" \
		--name "$(id -u)-${project}-${image_hash}" \
		"${image_id}" \
		/bin/bash
	[ $? -eq 0 ] || log_die "Failed to create docker container"

	container_id=$(<"${SCRIPTDIR}/container_${project}.stamp")
	[ $? -eq 0 ] || log_die "Failed to get container"

	log_info "Setting up the container ${container_id}"

	run_cmd_silent docker container start ${container_id}
	[ $? -eq 0 ] || log_die "Failed to start container"

	run_cmd docker container exec ${container_id} \
		/usr/sbin/groupadd -g $(id -g) ${bbuser}
	[ $? -eq 0 ] || log_die "Failed to create group in container"

	run_cmd docker container exec ${container_id} \
		/usr/sbin/useradd -d ${bbhome} -u $(id -u) -g $(id -g) -s /bin/bash \
			${bbuser}
	[ $? -eq 0 ] || log_die "Failed to create user in container"

	# chown the home directory to the container user
	run_cmd docker container exec ${container_id} \
		chown ${bbuser}:${bbuser} "${bbhome}/"
	[ $? -eq 0 ] || log_die "Failed to change ownership of home dir"

	# install skel manually since we could not properly create the home dir
	run_cmd docker container exec ${container_id} \
		find /etc/skel/ -type f -exec \
			install -m 0644 -o ${bbuser} -g ${bbuser} {} "${bbhome}/" '\;'
	[ $? -eq 0 ] || log_die "Failed to copy skel for container user"

	run_cmd docker container exec ${container_id} \
		/bin/chown ${bbuser}:${bbuser} "${bbdldir}/"
	[ $? -eq 0 ] || log_die "Failed to change ownership of mount points"

	log_info "Container ${container_id} is ready"
	log_info
}

# checks if the container checksum matches and triggers a rebuild otherwise
# also writes the checksum file
# globals:
#    image_id
fetch_docker_image ()
{
	local hasher="sha1sum"
	local extra_packages=
	local image_base=
	local image_hash_data=

	log_info "Calculating image hash"

	extra_packages=$(<"${SCRIPTDIR}/packages.list")
	image_base=$(<"${SCRIPTDIR}/container.base")

	# generate hash based on inputs relevant to image creation
	read -rd '' image_hash_data <<HASH_INTERNAL
$(type build_docker_image)
$(type fetch_docker_image)
$(type setup_docker_container)
$(<"${SCRIPTDIR}/packages.list")
$(<"${SCRIPTDIR}/docker/Dockerfile")
$(<"${SCRIPTDIR}/container.base")
HASH_INTERNAL

	image_hash=$(${hasher} <<<"${image_hash_data}" | cut -d ' ' -f 1)
	log_info "Image hash is ${image_hash}"

	# write the new version to the image version file
	cat >"${SCRIPTDIR}/image_${project}.version" <<< "${image_hash}"

	log_info "Checking availability of existing images"
	image_id=$(docker image ls -aqf "reference=${project}:${image_hash}")

	if [ -z "${image_id}" ]; then
		# build a new image based on the new hash
		log_info "No available images found. Building a new image"
		log_info

		build_docker_image \
			"${project}:${image_hash}" \
			"${image_base}" \
			"${extra_packages}"
	fi
}

# runs bitbake in a container given by container id
# params:
#    $1 - container id
run_bitbake ()
{
	local container_id=
	declare -i exit_status=0

	if [ ! -f "${SCRIPTDIR}/container_${project}.stamp" ]; then
		log_die "Unable to fetch container"
	fi

	container_id=$(<"${SCRIPTDIR}/container_${project}.stamp")
	bbcmd="${bbcmd:-"bitbake ${bbdryrun} ${bbcontinue} \"${bbtarget}\""}"

	log_info "Running build with the following parameters:"
	log_info "TARGET:     ${bbtarget}"
	log_info "MACHINE:    ${bbmachine}"
	log_info "REPO:       ${hostsrcdir}"
	log_info "DL_DIR:     ${hostdldir}"
	log_info "BUILD_DIR:  ${hostoutdir}"
	log_info

	run_cmd_silent docker container start ${container_id}
	[ $? -eq 0 ] || log_die "Failed to start container"

	run_cmd${bbinteractive} docker container exec \
		${bbshell} \
		--user ${bbuser} \
		--workdir ${bbhome} \
		--env "TEMPLATECONF=${bbsrc}/conf" \
		--env "MACHINE=${bbmachine}" \
		--env "DL_DIR=${bbdldir}" \
		${container_id} \
		/bin/bash -c \
		"\". ${bbsrc}/poky/oe-init-build-env ${bbout}; \
		${bbcmd}\""

	exit_status=$?

	log_info "Stopping container"
	run_cmd_silent docker container stop ${container_id}
	[ $? -eq 0 ] || log_error "Failed to stop container"

	return ${exit_status}
}

do_main ()
{
	# globals required to communicate information across functions
	local container_id

	# gloabs set by parse_cmdline
	local bbshell=
	local bbtarget="${project}"
	local bbcmd=
	local bbinteractive=
	local bbdryrun=
	local bbcontinue=
	local bbkeepcontainer=
	local bbmachine="${default_machine}"

	# general read-only bb/container settings
	declare -r bbuser="builder"
	declare -r bbhome="/home/${bbuser}"
	declare -r bbsrc="${bbhome}/src"
	declare -r bbout="${bbsrc}/build_${project}"
	declare -r bbdldir="${bbhome}/${project}-downloads"

	# host global settings
	declare -r hostbash_history="${HOME}/.${project}_bash_history"
	declare -r hostnetrc="${HOME}/.netrc"
	declare -r hostdotssh="${HOME}/.ssh"
	declare -r hostdotsvn="${HOME}/.subversion"

	local hostsrcdir="${ROOTDIR}"
	local hostoutdir="${hostsrcdir}/build_${project}"
	local hostdldir="${HOME}/${project}-downloads"

	parse_cmdline "$@"
	check_user
	check_prerequisites

	# make sure to remove the generated containers, from this point onwards,
	# unless the user intends to keep the container
	if [ -z "${bbkeepcontainer}" ]; then
		trap cleanup_docker_containers EXIT
	fi

	check_project_revision
	setup_docker_container
	run_bitbake

	if [ $? -eq 0 ]; then
		log_info "Build finished successfully"
		return 0
	else
		log_error "Build finished with errors"
		return 1
	fi
}

do_main "$@"
exit $?
