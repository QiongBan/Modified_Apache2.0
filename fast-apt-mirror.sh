#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2024 QiongBan
# SPDX-FileContributor: QiongBan - modifications
# SPDX-License-Identifier: Apache-2.0

# This script is a modified version of fast-apt-mirror.sh originally developed by Vegard IT GmbH and Sebastian Thomschke,
# available at https://github.com/vegardit/fast-apt-mirror.sh/
# This modified version is maintained by [Your Name] and incorporates changes to [briefly describe the nature of modifications,
# e.g., "enhance architecture-specific handling and improve mirror selection based on user input"].
# The modifications are provided under the Apache 2.0 License, consistent with the original work.

# Acknowledgments:
# I would like to express my gratitude to Vegard IT GmbH and Sebastian Thomschke for the original development of the fast-apt-mirror.sh script.
# The open and collaborative nature of the original work has significantly contributed to the development of this modified version.
# shellcheck disable=SC2155 # (warning): Declare and assign separately to avoid masking return values

###################
# script init
###################
# execute script with bash if loaded with other shell interpreter
if [ -z "${BASH_VERSINFO:-}" ]; then /usr/bin/env bash "$0" "$@"; exit; fi

if (return 0 2>/dev/null); then
  >&2 echo "ERROR: ${BASH_SOURCE[0]} should not be sourced!"
  return
fi

if [[ ${BASH_VERSINFO} -lt 4 ]]; then
  >&2 echo "ERROR: ${BASH_SOURCE[0]} requires Bash 4 or higher!"
  exit 1
fi

set -uo pipefail


readonly RC_INVALID_ARGS=3
readonly RC_MISC_ERROR=222


#################################################
# configure logging/error reporting
#################################################
# alternative to set -e, which is ignored within function bodies:
set -o errtrace
# shellcheck disable=SC2154 # rc is referenced but not assigned.
trap 'rc=$?; if [[ $rc -ne '$RC_MISC_ERROR' && $rc -ne '$RC_INVALID_ARGS' ]]; then echo >&2 "$(date +%H:%M:%S) Error - exited with status $rc in $BASH_SOURCE at line $LINENO:"; cat -n $BASH_SOURCE | tail -n+$((LINENO - 3)) | head -n7; exit $rc; fi' ERR

# if TRACE_SCRIPTS=1 or TRACE_SCRIPTS contains a glob pattern that matches $0
# shellcheck disable=SC2053 # Quote the right-hand side of == in [[ ]] to prevent glob matching
if [[ ${TRACE_SCRIPTS:-} == "1" || "$0" == ${TRACE_SCRIPTS:-} ]]; then
  if [[ $- =~ x ]]; then
    # "set -x" was specified already, we only improve the PS4 in this case
    PS4='+\033[90m[$?] $BASH_SOURCE:$LINENO ${FUNCNAME[0]}()\033[0m '
  else
    # "set -x" was not specified, we use a DEBUG trap for better debug output
    set -o functrace

    __trace() {
      printf "\e[90m#[$?] ${BASH_SOURCE[1]}:$1 ${FUNCNAME[1]}() %*s\e[35m$BASH_COMMAND\e[m\n" "$(( 2 * (BASH_SUBSHELL + ${#FUNCNAME[*]} - 2) ))" >&2
    }
    trap '__trace $LINENO' DEBUG
  fi
fi


#################################################
# script body
#################################################
readonly DESC_CURRENT='Prints the currently configured APT mirror.'
readonly DESC_FIND="Finds and prints the URL of a fast APT mirror and optionally applies it using the '$(basename "$0") set' command."
readonly DESC_SET="Configures the given APT mirror in /etc/apt/(sources.list|sources.list.d/system.sources) and runs 'sudo apt-get update'."

# workaround to prevent: "xargs: environment is too large for exec" in some environments
function __xargs() {
  env -i HOME="$HOME" LC_CTYPE="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" PATH="$PATH" TERM="${TERM:-}" USER="${USER:-}" xargs "$@"
}

function __sudo() {
  if [[ "$EUID" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

function assert_option_is_int() {
  if ! [ "$2" -eq "$2" ] 2>/dev/null; then
    echo "Option $1: '$2' is not a valid integer"
    exit 1
  fi
}

function get_dist_name() {
  if compgen -G "/etc/*-release" >/dev/null; then
    cat /etc/*-release | grep "^ID=" | cut -d= -f2
  else
    echo "$OSTYPE"
  fi
}

function get_dist_version_name() {
  if compgen -G "/etc/*-release" >/dev/null; then
    cat /etc/*-release | grep VERSION_CODENAME | cut -d= -f2
  else
    echo "unkown"
  fi
}

function matches() {
  local text=$1 pattern=$2
  [[ $text =~ $pattern ]]
}

function read_main_mirror_from_deb822_file() {
  # https://repolib.readthedocs.io/en/latest/deb822-format.html
  file=$1
  [[ -f $file ]] || return 0
  local line mirror_uri='' mirror_main=''
  while IFS= read -r line; do
    if [[ -z $line ]]; then mirror_uri=; mirror_main=; continue; fi
    if matches "$line" 'URIs:\s+([^ ]+)'; then mirror_uri=${BASH_REMATCH[1]}; continue; fi
    if matches "$line" 'Components:\s+.*(main)(\s+|$)'; then mirror_main=true; continue; fi
    if [[ -n $mirror_uri && "$mirror_main" == "true" ]]; then
      echo "$mirror_uri"
      return
    fi
  done < "$file"
}


############################
# returns two lines:
# 1. mirror URL
# 2. config file where the mirror URL was defined
############################
function get_current_mirror() {
  >&2 echo -n "Current mirror: "
  local dist_name=$(get_dist_name)
  case $dist_name in
    debian|ubuntu|pop)
       ;;
    *) >&2 echo "unknown (Unsupported operating system: $dist_name)"
       return $RC_MISC_ERROR
       ;;
  esac

  local current_mirror_url=''
  local current_mirror_cfgfile
  case $dist_name in
    debian)     current_mirror_cfgfile='/etc/apt/sources.list.d/debian.sources' ;;
    ubuntu|pop) current_mirror_cfgfile='/etc/apt/sources.list.d/system.sources' ;;
  esac
  current_mirror_url=$(read_main_mirror_from_deb822_file "$current_mirror_cfgfile")

  if [[ -z $current_mirror_url ]]; then
    if [[ -f /etc/apt/sources.list ]]; then
       if grep -q -E "^deb\s+mirror\+file:/etc/apt/apt-mirrors.txt\s+.*\s+main" /etc/apt/sources.list; then
         current_mirror_url=$(awk 'NR==1 { print $1 }' /etc/apt/apt-mirrors.txt)
         current_mirror_cfgfile=/etc/apt/apt-mirrors.txt
       else
         current_mirror_url=$(grep -E "^deb\s+(https?|ftp)://.*\s+main" /etc/apt/sources.list | awk 'NR==1 { print $2 }')
         current_mirror_cfgfile=/etc/apt/sources.list
       fi
    fi
  fi

  if [[ -z $current_mirror_url ]]; then
    >&2 echo "unknown"
    return
  fi

  >&2 echo "$current_mirror_url ($current_mirror_cfgfile)"

  # if function is piped or output is caputured write the selected APT mirror to STDOUT
  if [[ -p /dev/stdout ]]; then
    echo "$current_mirror_url"
    echo "$current_mirror_cfgfile"
  fi
}


shopt -s extglob

function find_fast_mirror() {
  if ! hash curl &>/dev/null; then
    >&2 echo "INFO: Required command 'curl' not found, trying to install it..."
    __sudo apt-get -o Acquire::http::Timeout=10 update && \
    __sudo apt-get -o Acquire::http::Timeout=10 install -y --no-install-recommends curl ca-certificates || return $RC_MISC_ERROR
  fi

  local start_at=$(date +%s)
  #
  # argument parsing
  #
  while [ $# -gt 0 ]; do
    case $1 in
      -p|--parallel)  assert_option_is_int "$1" "$2"; shift; local download_parallel=$1 ;;
      --healthchecks) assert_option_is_int "$1" "$2"; shift; local max_healthchecks=$1 ;;
      --speedtests)   assert_option_is_int "$1" "$2"; shift; local max_speedtests=$1 ;;
      --sample-size)  assert_option_is_int "$1" "$2"; shift; local sample_size_kb=$1 ;;
      --sample-time)  assert_option_is_int "$1" "$2"; shift; local sample_time_secs=$1 ;;
      --apply)             local apply=true ;;
      --exclude-current)   local exclude_current=true ;;
      --ignore-sync-state) local ignore_sync_state=true ;;
      --verbose)           local verbosity=$(( ${verbosity:-0} + 1 )) ;;
      -+(v))               local verbosity=$(( ${verbosity:-0} + ${#1} - 1 )) ;;
      --help)
        echo "Usage: $(basename "$0") find [OPTION]...";
        echo
        echo "$DESC_FIND"
        echo
        echo "Options:"
        echo "     --apply             - Replaces the currently configured APT mirror in /etc/apt/(sources.list|sources.list.d/system.sources) with a fast mirror and runs 'sudo apt-get update'"
        echo "     --exclude-current   - If specified, don't include the currently configured APT mirror in the speed tests."
        echo "     --healthchecks N    - Number of mirrors from the mirrors list to check for availability and up-to-dateness - default is 20"
        echo "     --ignore-sync-state - Don't check up-to-dateness of mirrors as part of healthchecks"
        echo "     --speedtests N      - Maximum number of healthy mirrors to test for speed - default is 5"
        echo " -p, --parallel N        - Number of parallel speed tests. May result in incorrect results because of competing connections but finds a suitable mirror faster."
        echo "     --sample-size KB    - Number of kilobytes to download during the speed from each mirror - default is 200KB"
        echo "     --sample-time SECS  - Maximum number of seconds within the sample download from a mirror must finish - default is 3"
        echo " -v, --verbose           - More output. Specify multiple times to increase verbosity."
        return ;;
    esac
    shift
  done

  local download_parallel=${download_parallel:-1}
  local max_speedtests=${max_speedtests:-5}
  local sample_size_kb=${sample_size_kb:-200}
  local sample_time_secs=${sample_time_secs:-3}
  local max_healthchecks=${max_healthchecks:-20}
  local verbosity=${verbosity:-0}

  local dist_name=$(get_dist_name)
  case $dist_name in
    debian|ubuntu|pop)
      local dist_version_name=$(get_dist_version_name)
      local dist_arch=$(dpkg --print-architecture)
      ;;
    *) # use dummy values on unsupported Linux distributions so the speed test can still be executed
      local dist_name=ubuntu
      local dist_version_name=bionic
      #local dist_name=debian
      #local dist_version_name=bookworm
      local dist_arch=amd64
      ;;
  esac

  #
  # determine the current APT mirror
  #
  local current_mirror=$(get_current_mirror | head -n 1 || true)

  #
  # download mirror lists
  #
  >&2 echo -n "Randomly selecting $max_healthchecks mirrors..."
  local preferred_mirrors=()
  case $dist_name in
    debian)
      # see https://deb.debian.org/
      preferred_mirrors+=("$(curl --max-time 5 -sSL -o /dev/null http://deb.debian.org/debian -w "%{url_effective}")")
      local mirrors=$(curl --max-time 5 -sSL https://www.debian.org/mirror/list | grep -Eo '(https?|ftp)://[^"]+/debian/')
      local last_modified_path="/dists/${dist_version_name}-updates/main/Contents-${dist_arch}.gz"
      ;;
    ubuntu|pop)
    arch=$(dpkg --print-architecture)
      if [[ "$arch" == "amd64" ]]; then
      echo 'Which mirror list on http://mirrors.ubuntu.com/ would you prefer to use instead of mirrors.txt?'
      read mirror_list_file
      mirror_list_file=${mirror_list_file:-mirrors.txt}
      local mirrors=$(curl --max-time 5 -sSfL http://mirrors.ubuntu.com/$mirror_list_file)
    elif [[ "$arch" == "arm64" || "$arch" == "armhf" ]]; then
      local mirrors=$(wget -q -O- https://launchpad.net/ubuntu/+archivemirrors \
        | grep -P -B8 "status(UP|SIX)" \
        | grep -o -P "(https?|ftp)://[^\"]*" \
        | grep '/ubuntu-ports')
    else
      local mirrors=$(wget -q -O- https://launchpad.net/ubuntu/+archivemirrors \
        | grep -P -B8 "status(UP|SIX)" \
        | grep -o -P "(https?|ftp)://[^\"]*")
    fi
    local last_modified_path="/dists/${dist_version_name}-security/Contents-${dist_arch}.gz"
       ;;
  esac
  mirrors=$(echo "$mirrors" | sort -u)

  #
  # ignore or enforce inclusion of current_mirror
  #
  if [[ -n $current_mirror ]]; then
    if [[ ${exclude_current:-} == "true" ]]; then
      mirrors=$(echo "$mirrors" | grep -v "$current_mirror")
    else
      preferred_mirrors+=("$current_mirror")
    fi
  fi

  #
  # select preferred plus random mirros
  #
  if [[ ${#preferred_mirrors[@]} -gt 0 ]]; then
    local preferred_mirror
    for preferred_mirror in "${preferred_mirrors[@]}"; do
      mirrors=$(echo "$mirrors" | grep -v "$preferred_mirror")
    done
    mirrors=$(printf "%s\n" "${preferred_mirrors[@]}")$'\n'$(echo "$mirrors" | shuf -n $(( max_healthchecks - ${#preferred_mirrors[@]} )))
  else
    mirrors=$(echo "$mirrors" | shuf -n "$max_healthchecks")
  fi
  >&2 echo "done"

  mirrors=$(echo "$mirrors" | sort)
  if [[ $verbosity -gt 1 ]]; then
    for mirror in $mirrors; do >&2 echo " -> $mirror"; done
  fi

  #
  # checking reachability and sync status of mirrors
  #
  >&2 echo -n "Checking health status of $(echo "$mirrors" | wc -l) mirrors using '$last_modified_path'"
  # returns a list with content like:
  # 1675322068 http://archive.ubuntu.com/ubuntu/
  # 1675322068 http://ftp.halifax.rwth-aachen.de/ubuntu/
  #
  # shellcheck disable=SC2016 # Expressions don't expand in single quotes, use double quotes for that
  local healthcheck_results=$(echo "$mirrors" | \
    __xargs -i -P "$(echo "$mirrors" | wc -l)" bash -c \
       'last_modified=$(set -o pipefail; curl --max-time 3 -sSfL --head "{}'"${last_modified_path}"'" 2>/dev/null | grep -i "last-modified" | cut -d" " -f2- | LANG=C date -f- -u +%s || echo 0); echo "$last_modified {}"; >&2 echo -n "."'
  )
  >&2 echo "done"

  #
  # filter out broken and outdated mirrors
  #
  local healthcheck_results_sorted_by_date=$(echo "$healthcheck_results" | sort -t' ' -k1,1rn -k2) # sort by last modified date and URL
  local healthy_mirrors_date=${healthcheck_results_sorted_by_date%% *} # the last modified date of healthy up-to-date mirrors
  if [[ $verbosity -gt 0 ]]; then
    while IFS= read -r mirror; do
      local last_modified=${mirror%% *}
      local mirror_url=${mirror#* }
      case $last_modified in
        "$healthy_mirrors_date") >&2 echo " -> UP-TO-DATE (last modified: $(date -d "@$last_modified" +'%Y-%m-%d %H:%M:%S %Z')) $mirror_url" ;;
        0)                       >&2 echo " ->                         n/a                          $mirror_url" ;;
        *)                       >&2 echo " -> outdated   (last modified: $(date -d "@$last_modified" +'%Y-%m-%d %H:%M:%S %Z')) $mirror_url" ;;
      esac
    done <<< "$healthcheck_results_sorted_by_date"
  fi
  if [[ ${ignore_sync_state:-} == "true" ]]; then
    local healthy_mirrors=$(echo "$healthcheck_results_sorted_by_date" | grep -v "^0 " | cut -d" " -f2-)
    >&2 echo " => $(echo "$healthy_mirrors" | wc -l) mirrors are reachable"
  else
    local healthy_mirrors=$(echo "$healthcheck_results_sorted_by_date" | grep "^$healthy_mirrors_date " | cut -d" " -f2-)
    >&2 echo " => $(echo "$healthy_mirrors" | wc -l) mirrors are reachable and up-to-date"
  fi

  #
  # select mirrors for the speed test
  #
  local speedtest_mirrors=''
  if [[ ${#preferred_mirrors[@]} -gt 0 ]]; then
    for preferred_mirror in "${preferred_mirrors[@]}"; do
      if [[ $healthy_mirrors = *"$preferred_mirror"* ]]; then
        speedtest_mirrors+=$preferred_mirror$'\n'
      fi
    done
  fi
  # awk '!x[$0]++' -> https://stackoverflow.com/a/11532197/5116073
  speedtest_mirrors=$(echo "$speedtest_mirrors$healthy_mirrors" | awk '!x[$0]++' | head -n "$max_speedtests")

  #
  # test download speed and select fastest mirror
  #
  >&2 echo -n "Speed testing $(echo "$speedtest_mirrors" | wc -l) of the available $(echo "$healthy_mirrors" | wc -l) mirrors (sample download size: $((sample_size_kb))KB)"
  local mirrors_with_speed=$(
    echo "$speedtest_mirrors" \
    | __xargs -P $((download_parallel)) -i bash -c \
          "curl -r 0-$((sample_size_kb*1024)) --max-time $((sample_time_secs)) -sSf -w '%{speed_download} {}\n' -o /dev/null {}ls-lR.gz 2>/dev/null || true; >&2 echo -n '.'" \
    | sort -rg
  )
  >&2 echo "done"
  if [[ -z $mirrors_with_speed ]]; then
    >&2 echo "ERROR: Could not determine any fast mirror matching required criterias."
    return $RC_MISC_ERROR
  fi
  local fastest_mirror=$(echo "${mirrors_with_speed%%$'\n'*}" | cut -d" " -f2)
  fastest_mirror_speed=$(echo "${mirrors_with_speed%%$'\n'*}" | cut -d" " -f1 | numfmt --to=iec --suffix=B/s)
  local speed_test_duration=$(( $(date +%s) - start_at ))
  if [[ $verbosity -gt 0 ]]; then
    echo "$mirrors_with_speed" | tail -n +2 | tac | while IFS= read -r mirror; do
      mirror_speed=$(echo "${mirror%%$'\n'*}" | cut -d" " -f1 | numfmt --to=iec --suffix=B/s)
      >&2 echo " -> $(echo "$mirror" | cut -d" " -f2) ($mirror_speed)"
    done
  fi
  >&2 echo " => $fastest_mirror ($fastest_mirror_speed) determined as fastest mirror within $speed_test_duration seconds"

  if [[ ${apply:-} == "true" ]]; then
    set_mirror "$fastest_mirror" >&2 || return $?
  fi

  #
  # if function output is redirected/captured then write the selected mirror to STDOUT
  #
  if [[ -p /dev/stdout ]]; then
    echo "$fastest_mirror"
  fi
}


function set_mirror() {
  #
  # argument parsing
  #
  if [[ "${1:-}" == "--help" ]]; then
    echo "Usage: $(basename "$0") set MIRROR_URL";
    echo
    echo "$DESC_SET"
    echo
    echo "Parameters:"
    echo "  MIRROR_URL - the APT mirror URL to configure."
    return
  fi

  local new_mirror=${1:-}
  if [[ -z $new_mirror ]]; then
    echo "ERROR: Cannot set APT mirror: MIRROR_URL not specified!"
    echo
    set_mirror --help
    return $RC_INVALID_ARGS
  fi
  if ! matches "${new_mirror,,}" '^(https?|ftp)://'; then
    echo "ERROR: Cannot set APT mirror: malformed URL or unsupported protocol: $new_mirror"
    return $RC_INVALID_ARGS
  fi

  dist_name=$(get_dist_name)
  case $dist_name in
    debian|ubuntu|pop) ;;
    *) echo "ERROR: Cannot set APT mirror: unsupported operating system: $dist_name"; return $RC_MISC_ERROR ;;
  esac

  #
  # determine the current mirror
  #
  local current_mirror
  readarray -t current_mirror < <(get_current_mirror || true)
  if [[ ${#current_mirror[@]} -lt 1 ]]; then
    echo "ERROR: Cannot set APT mirror: cannot determine current APT mirror."
    return $RC_MISC_ERROR
  fi

  #
  # reconfigure APT if necessary
  #
  if [[ "${current_mirror[0]}" == "$new_mirror" ]]; then
    echo "Nothing to do, already using: $new_mirror"
  else
    local backup="${current_mirror[1]}.$(date +'%Y%m%d_%H%M%S').save"
    echo "Creating backup $backup"
    __sudo cp "${current_mirror[1]}" "$backup"
    echo "Changing mirror from [${current_mirror[0]}] to [$new_mirror] in (${current_mirror[1]})..."
    __sudo sed -i \
      -e "s|${current_mirror[0]}\$|$new_mirror|g" \
      -e "s|${current_mirror[0]} |$new_mirror |g" \
      -e "s|${current_mirror[0]}\t|$new_mirror\t|g" \
      "${current_mirror[1]}"
    __sudo apt-get -o Acquire::http::Timeout=10 update
    echo "Successfully changed mirror from [${current_mirror[0]}] to [$new_mirror] in (${current_mirror[1]})"
  fi
}


#
# main entry point
#
case ${1:-} in
  find)    shift; find_fast_mirror "$@" ;;
  set)     shift; set_mirror "$@" ;;
  current) shift; get_current_mirror "$@" | head -n 1 ;;
  *) [[ "${1:-}" == "--help" ]] || ( echo "ERROR: Required command missing"; echo )
     echo "Usage: $(basename "$0") COMMAND";
     echo
     echo "Available commands:"
     echo " current - $DESC_CURRENT"
     echo " find    - $DESC_FIND"
     echo " set     - $DESC_SET"
     [[ "${1:-}" == "--help" ]] || exit $RC_INVALID_ARGS
     ;;
esac
