#
# logger.sh - general purpose logging library with custom timestamps
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

add_timestamp ()
{
	gawk '\
	{ \
		now=strftime("[%Y-%m-%d_%H-%M-%S] "); \
		sub(/^/, now);print;system(""); \
	}'
}

# prepend timestamp to each line of output
exec 1> >(add_timestamp)
exec 2> >(add_timestamp >&2)

# log prefix
export LOG_PREFIX="${0##*/}:"
export PS4='+${0##*/}:${LINENO}:${FUNCNAME:-}: '

log_info ()
{
	echo "${LOG_PREFIX} INFO: $@"
}
export -f log_info

log_warn ()
{
	echo "${LOG_PREFIX} WARN: $@" 1>&2
}
export -f log_warn

log_error ()
{
	echo "${LOG_PREFIX} ERROR: $@" 1>&2
	return 1
}
export -f log_error

log_die ()
{
	echo "${LOG_PREFIX} FATAL: $@" 1>&2
	exit 1
}
export -f log_die
