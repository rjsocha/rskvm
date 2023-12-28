#!/usr/bin/env bash
#
# ██████╗ ███████╗██╗  ██╗██╗   ██╗███╗   ███╗
# ██╔══██╗██╔════╝██║ ██╔╝██║   ██║████╗ ████║
# ██████╔╝███████╗█████╔╝ ██║   ██║██╔████╔██║
# ██╔══██╗╚════██║██╔═██╗ ╚██╗ ██╔╝██║╚██╔╝██║
# ██║  ██║███████║██║  ██╗ ╚████╔╝ ██║ ╚═╝ ██║
# ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝  ╚═══╝  ╚═╝     ╚═╝
#
# Usage:
#  rskvm [--verbose] [--force] <[--full] [--no-config] [?|+|-]name[/template][@host][:ram][:cpu]> <...>
#  rskvm config::host disable:local +-me:<name> +-host:<name> +-address:<address> +-user:<name> +-auth:<key|agent> +-ssh-key:<key-file> +-port:<ssh-port>
#  rskvm config::vm +-user:<user>@[<PASSWORD|?>] +-group:<group>@<user> +-ssh-key:<user>@<ssh-public-file> +-profile:<name> get show list
#  rskvm config::vm profile:<name> generate-ssh-keys:ON|OFF
#  rskvm setup::host [--force]
#  rskvm setup::host:<name> overlay-network:zt zt-net:<net> subnet:<prefix>
#  rskvm me:install me:version
#
#  Overlay ZT network:
#
#    rskvm overlay:zt:name:<ZT-NAME>
#    rskvm overlay:zt:api:<ZT-API-KEY>
#    rskvm overlay:zt:network:<ZT-NETWORK-ID>
#    rskvm overlay:zt:verify
#
#  Host setup:
#
#    rskvm config:host host:<NAME> address:<FQDN> user:<USER> port:<SSH-PORT>
#    rskvm setup:host:vm1 zt:<ZT-NAME> subnet:10.244.244.0/24 [zt-ip:<ZT-NODE-IP>]
#
#  Templates:
#
#    rskvm default-image:<name>
#    rskvm list:templates
#    rskvm update:templates
#    rskvm --image-unused [--purge]
#    rskvm --image-used
#
# EOU
# Above EOU tag is required  as a mark of End Of Usage

set -eE

export ME=rskvm
export NSURI="http://rskvm.socha.it/"
export PREFERED_TEMPLATE=(ubuntu-20.04 debian-10 ubuntu-18.04)
export DEFAULT_RAM=1024
export DEFAULT_CPU=1
export LIBVIRT_DEFAULT_URI="qemu:///system"
export KVMREPO="http://kvm.socha.it"
export ZT_API="https://my.zerotier.com/api/v1"
export IS_REMOTE=0
export COLOR="${COLOR:-yes}"
CURL_TIMEOUT=10

_trap_error() {
local frame=0 LINE SUB FILE
  while read LINE SUB FILE < <(caller "$frame")
  do
    if [[ ${frame} -eq 0 ]]
    then
      _printf "{G}%s{N} @ {R}%s{N} return code was {Y}%s\n" "${SUB}" "${LINE}" "$1" || true
    else
      _printf "%-${frame}s{G}%s{N} @ {R}%s{N}\n" "" "${SUB}" "${LINE}" || true
    fi
    ((frame++)) || true
  done
}

_verbose_printf() {
  if [[ $VERBOSE -eq 1 ]]
  then
    _printf "$@"
  fi
}

_print_line() {
  if [[ -t 1 ]]
  then
    echo $@
  else
    echo -n $@
  fi
}

# example: _printf "{R}RED {B}BLUE {G}GREEN {Y}YELLOW {N}NEUTRAL"
_printf() {
local _text
  if [[ -z $1 ]]
  then
    set -- "\n"
  fi
  if [[ $COLOR == "no" ]]
  then
    local _RED=''
    local _GREEN=''
    local _YELLOW=''
    local _BLUE=''
    local _MAGENTA=''
    local _CYAN=''
    local _NEUTRAL=''
    local _BOLD=''
    local _UNDERLINE=''
    local _BLINK=''
  else
    local _RED='\e[31m'
    local _GREEN='\e[32m'
    local _YELLOW='\e[33m'
    local _BLUE='\e[34m'
    local _MAGENTA='\e[35m'
    local _CYAN='\e[36m'
    local _NEUTRAL='\e[0m'
    local _BOLD='\e[1m'
    local _UNDERLINE='\e[4m'
    local _BLINK='\e[5m'
  fi
  _text="$1"
  shift
  if [[ $_text =~ \{N\}$ ]]
  then
   _text="${_text%\{N\}}"
  else
   _text="${_text}{N}"
  fi
  _text="${_text//\{G\}/$_GREEN}"
  _text="${_text//\{B\}/$_BLUE}"
  _text="${_text//\{Y\}/$_YELLOW}"
  _text="${_text//\{R\}/$_RED}"
  _text="${_text//\{C\}/$_CYAN}"
  _text="${_text//\{M\}/$_MAGENTA}"
  _text="${_text//\{\*\}/$_BOLD}"
  _text="${_text//\{\_\}/$_UNDERLINE}"
  _text="${_text//\{\+\}/$_BLINK}"
  _text="${_text//\{N\}/$_NEUTRAL}"
  printf "$_text" "$@"
}

_abort_script() {
local _f=$1
  shift
  _printf "{R}ERROR({Y}%s{R}){N}: ${_f}\n" "$(_who_am_i)" $@
  exit 1
}

_check_var() {
local be_quiet=0
  if [[ $1 == "-q" ]]
  then
    shift
    be_quiet=1
  fi
  if [[ -z ${!1} ]]
  then
   _abort_script "missing environment variable {G}${1}"
  fi
  if [[ $be_quiet -eq 0 ]]
  then
    _printf "{Y}Checking environment variable {C}$1{N}: {G}OK\n"
  fi
}

_realpath() {
local _v="$1"
  _v="${_v/#\~/$HOME}"
  if [[ -f ${_v} ]]
  then
    echo "${_v}"
    return 0
  fi
  return 1
}

_usage() {
local _me=$(realpath -eq $0)
  _printf "{G}{N}"
  tail -q -n+2 "${_me}" | head -q -n 7 | sed "s/^#//" |  grep -v "^$" >&2
  _printf "{Y}{N}"
  sed -n '/^# Usage/,${p;/^# EOU/q}' "${_me}" | head -q -n-1 | sed "s/^#//" >&2
  _printf "{N}{N}"
}

_config_rm() {
local _path="$1"
  if [[ ${_path:0:1} != "/" ]]
  then
    _path="/${_path}"
  fi
  if [[ ${_path} == "/" ]]
  then
    return 0
  fi
  if [[ -d ${CONFIG}${_path} ]]
  then
    rm -rf "${CONFIG}${_path}"
  elif [[ -f ${CONFIG}${_path} ]]
  then
    rm -f "${CONFIG}${_path}"
  fi
}

_config_get() {
local _path="$1"
  if [[ ${_path:0:1} != "/" ]]
  then
    _path="/${_path}"
  fi
  if [[ -f ${CONFIG}${_path} ]]
  then
    if [[ "${2}" != "check" ]]
    then
      cat 2>/dev/null "${CONFIG}${_path}" || return 1
    fi
    return 0
  fi
  return 1
}

# src
# dst
_config_link() {
local _src="$1" _dst="$2" _sub _src_path="" _dst_path=""
  shift 2
  if [[ $_src =~ / ]]
  then
    while [[ ${_src} =~ / ]]
    do
      _sub="${_src%%/*}"
      _src="${_src#*/}"
      if [[ -z ${_sub} ]]
      then
        continue
      fi
      _src_path="${_src_path}/${_sub}"
    done
  fi
  if [[ $_dst =~ / ]]
  then
    while [[ ${_dst} =~ / ]]
    do
      _sub="${_dst%%/*}"
      _dst="${_dst#*/}"
      if [[ -z ${_sub} ]]
      then
        continue
      fi
      _dst_path="${_dst_path}/${_sub}"
    done
  fi
  if [[ -L ${CONFIG}${_dst_path}/${_dst} ]] || [[ ! -e ${CONFIG}${_dst_path}/${_dst} ]]
  then
    if [[ ! -d ${CONFIG}${_dst_path} ]]
    then
      mkdir -p "${CONFIG}${_dst_path}"
    fi
    ln -srnf "${CONFIG}${_src_path}/${_src}" "${CONFIG}${_dst_path}/${_dst}"
  fi
}

_config_put() {
local _path="$1" _sub _full=""
  shift
  if [[ $_path =~ / ]]
  then
    while [[ ${_path} =~ / ]]
    do
      _sub="${_path%%/*}"
      _path="${_path#*/}"
      if [[ -z ${_sub} ]]
      then
        continue
      fi
      _full="${_full}/${_sub}"
      if [[ ! -d "${CONFIG}${_full}" ]]
      then
        mkdir -p "${CONFIG}${_full}"
      fi
    done
  fi
  if [[ -n ${_path} ]]
  then
    echo -n "$@"  > "${CONFIG}$_full/${_path}"
  fi
}

# $1 - root, [$2 - type: key or tree]
_config_find_all() {
local _path=$1 _type=$2 _key
    if [[ ${_path:0:1} != "/" ]]
    then
        _path="/${_path}"
    fi
    if [[ ${_type} != "key" ]]
    then
      _type="tree"
    fi
    if [[ -d ${CONFIG}${_path} ]]
    then
      for _key in $(find "${CONFIG}${_path}" -mindepth 1 -maxdepth 1 -printf "%f\n")
      do
        if [[ ${_type} == "tree" ]] && [[ -d ${CONFIG}${_path}/${_key} ]]
        then
          echo "${_key}"
        elif [[ ${_type} == "key" ]] && [[ -f ${CONFIG}${_path}/${_key} ]]
        then
         echo "${_key}"
        fi
      done
    fi
}

_verify_hostname() {
  if [[ ${1} =~ ^(([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\-]*[a-zA-Z0-9])\.)*([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9\-]*[A-Za-z0-9])$ ]]
  then
    return 0
  fi
  return 1
}

_verify_name() {

  if [[ ${1} =~ ^[a-z][a-z0-9.-]*[a-z0-9]$ ]]
  then
    return 0
  fi
  return 1
}

_require_runtime() {
  if [[ -n ${_runtime[$1]} ]]
  then
    return 0
  fi
  return 1
}

_config_ready() {
  _check_var -q CONFIG
  if [[ ! -d $CONFIG ]]
  then
    mkdir -p -m 0700 "$CONFIG"
    if [[ ! -d $CONFIG ]]
    then
      _abort_script "unable to create config directory at {G}${CONFIG}"
    fi
  fi
}

_config_host_add() {
  if [[ -n $1 ]]
  then
    if _verify_hostname "$1"
    then
      _config_put "host/${1}/"
      if ! _config_get "host/${1}/address" check
      then
        _config_put "host/${1}/address" "${1}"
      fi
      if ! _config_get "host/${1}/silent" check
      then
        _config_put "host/${1}/silent" "true"
      fi
      _runtime[host]="${1}"
    else
      _abort_script "incorrect hostname {G}%s" "${1}"
    fi
  else
    _abort_script "missing hostname for {G}config::host{N}"
  fi
}

_config_host_auth() {
  if [[ -n $1 ]]
  then
    case "${1,,}" in
      agent)
        _config_put "host/${_runtime[host]}/auth" "agent"
        ;;
      key)
        _config_put "host/${_runtime[host]}/auth" "key"
        ;;
      *)
        _abort_script "incorrect auth type {G}%s" "${1}"
    esac
  else
    _abort_script "missing auth type for {G}config::host{N}"
  fi
}

_config_host_address() {
  if [[ -n $1 ]]
  then
    if _verify_hostname "$1"
    then
      _config_put "host/${_runtime[host]}/address" "${1}"
    else
      _abort_script "incorrect hostname {G}%s" "${1}"
    fi
  else
    _config_rm "host/${_runtime[host]}/address"
  fi
}

_config_host_user() {
local _val
  if [[ -n $1 ]]
  then
    _config_put "host/${_runtime[host]}/user" "${1}"
  else
    _config_rm "host/${_runtime[host]}/user"
  fi
}

_config_host_port() {
local _val
  if [[ -n $1 ]]
  then
    if [[ ${1} =~ ^[0-9]+$ ]] && [[ ${1} -ge 1 ]] && [[ ${1} -le 65535 ]]
    then
      _config_put "host/${_runtime[host]}/port" "${1}"
    else
      _abort_script "incorrect host {G}port{N} number: {Y}%s" "${1}"
    fi
  else
    _config_rm "host/${_runtime[host]}/port"
  fi
}

_config_host_key() {
local _val
  if [[ -n $1 ]]
  then
    if _val=$(_realpath "${1}")
    then
      _config_put "host/${_runtime[host]}/key" "${1}"
    else
      _abort_script "missing key file {G}%s" "${1}"
    fi
  else
    _config_rm "host/${_runtime[host]}/key"
  fi
}

_config_host_zt_remove() {
local _host="${1}" _zt_node _zt_address _subnet _zt_net

  if ! _subnet=$(_config_get /host/${_host}/subnet)
  then
     _subnet=$(_config_get /host/${_host}/zt_subnet) || true
  fi
  if _zt_net=$(_config_get /host/${_host}/overlay/zt/network)
  then
    _config_put "/overlay/zt/current" "${_zt_net}"
  fi
  if ! _zt_node=$(_config_get /host/${_host}/overlay/zt/node)
  then
    _zt_node=$(_config_get /host/${_host}/zt) || true
  fi
  if ! _zt_address=$(_config_get /host/${_host}/overlay/zt/address)
  then
    _zt_address=$(_config_get /host/${_host}/zt_address) || true
  fi
  if [[ -n ${_subnet} ]]
  then
    if [[ -n ${_zt_node} ]] && [[ -n ${_zt_address} ]]
    then
      _verbose_printf "Removing route for {Y}%s{N} via {G}%s{N} / {G}%s\n" "${_subnet}" "${_zt_node}" "${_zt_address}"
      _zt_del_route "${_subnet}" "${_zt_address}"
      _verbose_printf "Removing node {G}%s{N} / {G}%s{N} from network\n" "${_zt_node}" "${_zt_address}"
      _zt_unauthorize_node "${_zt_node}" >/dev/null
    fi
  fi
}

_config_host_rm() {
  if [[ -n $1 ]]
  then
    if _verify_hostname "$1"
    then
      _config_host_zt_remove "${1}"
      _config_rm "host/${1}/"
    else
      _abort_script "incorrect hostname {G}%s" "${1}"
    fi
  else
    _abort_script "missing hostname for {G}config::host{N}"
  fi
}

_config_get_host() {
local _host="$1" _val=""
  if _val=$(_config_get /host/${_host}/address)
  then
    if [[ -n ${_val} ]]
    then
      echo "${_val}"
      return 0
    fi
  fi
  echo "${_host}"
}

_config_host_list() {
  _config_find_all host tree | sort
}

_config_host_show_key() {
local _host="${_runtime[host]}" _val=""
  if _val=$(_config_get "/host/${_host}/${1}")
  then
    echo -n "$_val"
  fi
}

_config_host_show() {
local _host="${_runtime[host]}" _val="" _w=-8
  if _val=$(_config_get /host/${_host}/address)
  then
    _printf "{G}%${_w}s {N}%s\n" "ADDRESS:" "$_val"
  else
    _printf "{G}%${_w}s {N}%s {Y}(default)\n" "ADDRESS:" "$_host"
  fi
  if _val=$(_config_get /host/${_host}/user)
  then
    _printf "{G}%${_w}s {N}%s\n" "USER:" "$_val"
  else
    _printf "{G}%${_w}s {N}$USER {Y}(current)\n" "USER:"
  fi
  if _val=$(_config_get /host/${_host}/port)
  then
    _printf "{G}%${_w}s {N}%s\n" "PORT:" "$_val"
  else
    _printf "{G}%${_w}s {N}22 {Y}(default)\n" "PORT:"
  fi
  if _val=$(_config_get /host/${_host}/bridge)
  then
    _printf "{G}%${_w}s {N}%s\n" "BRIDGE:" "$_val"
  fi
  if _val=$(_config_get /host/${_host}/auth)
  then
    _printf "{G}%${_w}s {N}%s\n" "AUTH:" "$_val"
  else
    _printf "{G}%${_w}s {N}agent {Y}(default)\n" "AUTH:"
  fi
  if [[ ${_val} == "key" ]]
  then
    if _val=$(_config_get /host/${_host}/key)
    then
      _printf "{G}%${_w}s {N}%s\n" "KEY:" "$_val"
    fi
  fi
  if _val=$(_config_get /host/${_host}/subnet)
  then
    _printf "{G}%${_w}s {N}%s\n" "SUBNET:" "$_val"
  elif _val=$(_config_get /host/${_host}/zt_subnet)
  then
    _printf "{G}%${_w}s {N}%s\n" "SUBNET:" "$_val"
  fi
  if _val=$(_config_get /host/${_host}/overlay/zt/network)
  then
    _printf "{G}%${_w}s {N}%s\n" "ZT NET:" "$_val"
  fi
  if _val=$(_config_get /host/${_host}/overlay/zt/node)
  then
    _printf "{G}%${_w}s {N}%s\n" "ZT NODE:" "$_val"
  elif _val=$(_config_get /host/${_host}/zt)
  then
    _printf "{G}%${_w}s {N}%s\n" "ZT NODE:" "$_val"
  fi
  if _val=$(_config_get /host/${_host}/overlay/zt/address)
  then
    _printf "{G}%${_w}s {N}%s\n" "ZT IP:" "$_val"
  elif _val=$(_config_get /host/${_host}/zt_address)
  then
    _printf "{G}%${_w}s {N}%s\n" "ZT IP:" "$_val"
  fi
  #if _val=$(_config_get /host/${_host}/silent)
  #then
  #  if [[ ${_val} != "true" ]]
  #  then
  #    _val="false"
  #  fi
  #  _printf "{G}%${_w}s {N}%s\n" "SILENT:" "$_val"
  #fi
}

_config_vm_ssh_key_rm() {
local _uinfo="$1" _user _key
  if [[ ${_uinfo} =~ @ ]]
  then
    _user="${_uinfo%@*}"
    _key="${_uinfo#*@}"
  else
    _abort_script "wrong key specified.."
  fi
  if [[ -n ${_key} ]]
  then
    _key="${_key/\//@}"
    _config_rm "vm/profile/${_runtime[profile]}/ssh-key/${_user}/${_key}"
  else
    _config_rm "vm/profile/${_runtime[profile]}/ssh-key/${_user}"
  fi
}

_config_vm_profile_list() {
  _config_find_all vm/profile tree
}

_config_vm_profile_show() {
local  _u _g _val _tmp _ssh _type _hash _comment _from
  _printf "{G}%s {N}{R}%s\n" "PROFILE:" "${_runtime[profile]}"

  # max text width
  _tmp=0
  if [[ -n $(_config_find_all "vm/profile/${_runtime[profile]}/group/" tree) ]]
  then
    for _g in $(_config_find_all "vm/profile/${_runtime[profile]}/group/" tree)
    do
      if [[ ${_tmp} -lt ${#_g} ]]
      then
        _tmp="${#_g}"
      fi
    done
  fi
  if [[ -n $(_config_find_all "vm/profile/${_runtime[profile]}/user/" key) ]]
  then
    for _u in $(_config_find_all "vm/profile/${_runtime[profile]}/user/" key)
    do
      if [[ ${_tmp} -lt ${#_u} ]]
      then
        _tmp="${#_u}"
      fi
    done
  fi
  if [[ -n $(_config_find_all "vm/profile/${_runtime[profile]}/ssh-key/" tree) ]]
  then
    for _u in $(_config_find_all "vm/profile/${_runtime[profile]}/ssh-key/" tree)
    do
      if [[ ${_tmp} -lt ${#_u} ]]
      then
        _tmp="${#_u}"
      fi
    done
  fi

  # show
  if [[ -n $(_config_find_all "vm/profile/${_runtime[profile]}/user/" key) ]]
  then
    _printf "{G}%s\n" "USER:"
    for _u in $(_config_find_all "vm/profile/${_runtime[profile]}/user/" key)
    do
      if [[ -n $(_config_get "vm/profile/${_runtime[profile]}/user/${_u}") ]]
      then
        _printf "  {N}{*}%${_tmp}s{N}{Y}*\n" "${_u}"
      else
        _printf "  {N}%${_tmp}s\n" "${_u}"
      fi
    done
  fi
  if [[ -n $(_config_find_all "vm/profile/${_runtime[profile]}/group/" tree) ]]
  then
    _printf "{G}%s\n" "GROUP:"
    for _g in $(_config_find_all "vm/profile/${_runtime[profile]}/group/" tree)
    do
      _printf "  {N}%${_tmp}s " "${_g}"
      _val=0
      for _u in $(_config_find_all "vm/profile/${_runtime[profile]}/group/${_g}" key)
      do
        if [[ ${_val} -eq 0 ]]
        then
          _printf "{Y}%s" "${_u}"
        else
          _printf ", {Y}%s" "${_u}"
        fi
        ((_val++)) || true
      done
      _printf "\n"
    done
  fi
  if [[ -n $(_config_find_all "vm/profile/${_runtime[profile]}/ssh-key/" tree) ]]
  then
    _printf "{G}%s\n" "SSH KEYS:"
    for _u in $(_config_find_all "vm/profile/${_runtime[profile]}/ssh-key/" tree)
    do
      _printf "  {N}%${_tmp}s\n" "${_u}"
      for _hash in $(_config_find_all "vm/profile/${_runtime[profile]}/ssh-key/${_u}" tree)
      do
        _printf "  {N}%${_tmp}s{Y}%s" " " "${_hash/@/\/}"
        _comment=$(_config_get "vm/profile/${_runtime[profile]}/ssh-key/${_u}/${_hash}/comment") || true
        _from=$(_config_get "vm/profile/${_runtime[profile]}/ssh-key/${_u}/${_hash}/from") || true
        _type=$(_config_get "vm/profile/${_runtime[profile]}/ssh-key/${_u}/${_hash}/type") || true
        _printf " {C}(%s / %s / %s)\n" "$_from" "${_type}" "${_comment}"
      done
    done
  fi
  _printf "{G}%s" "GENERATE SSH KEYS:"
  if [[ -n $(_config_get "vm/profile/${_runtime[profile]}/generate-ssh-keys") ]]
  then
    _printf " {Y}%s\n" "ON"
  else
    _printf " {Y}%s\n" "OFF"
  fi
  return 0
}

_config_vm_profile_get() {
local _u _p _g _connfig _val _tmp _ssh _type _hash _comment _from _key
  _config="kvm-cnf-no-net"
  if _p=$(_config_get "vm/profile/${_runtime[profile]}/generate-ssh-keys}")
  then
    _config="${_config}!regenerate-ssh-host-keys"
  fi
  if [[ -n $(_config_find_all "vm/profile/${_runtime[profile]}/user/" key) ]]
  then
    for _u in $(_config_find_all "vm/profile/${_runtime[profile]}/user/" key)
    do
      _p=$(_config_get "vm/profile/${_runtime[profile]}/user/${_u}")
      if [[ -n ${_p} ]]
      then
        _config="${_config}!user:${_u}@${_p}"
      else
        _config="${_config}!user:${_u}"
      fi
    done
  fi
  if [[ -n $(_config_find_all "vm/profile/${_runtime[profile]}/group/" tree) ]]
  then
    for _g in $(_config_find_all "vm/profile/${_runtime[profile]}/group/" tree)
    do
      for _u in $(_config_find_all "vm/profile/${_runtime[profile]}/group/${_g}" key)
      do
        _config="${_config}!group:${_u}@${_g}"
      done
    done
  fi
  if [[ -n $(_config_find_all "vm/profile/${_runtime[profile]}/ssh-key/" tree) ]]
  then
    for _u in $(_config_find_all "vm/profile/${_runtime[profile]}/ssh-key/" tree)
    do
      _key=$(for _hash in $(_config_find_all "vm/profile/${_runtime[profile]}/ssh-key/${_u}" tree)
      do
        _key=$(_config_get "vm/profile/${_runtime[profile]}/ssh-key/${_u}/${_hash}/key") || true
        if [[ -n $_key ]]
        then
         echo $(echo "$_key" | base64 -d)
        fi
      done | base64 -w 0)
      _config="${_config}!ssh:${_u}@${_key}"
    done
  fi
  echo "${_config}"
  return 0
}

_config_profile_rm() {
  if [[ -n $1 ]]
  then
    _config_rm "vm/profile/${1}/"
  else
    _abort_script "missing profile name for {G}config::vm:profile:rm{N}"
  fi
}

_config_vm_user_add() {
local _uinfo="$1" _user="" _passowrd=""
  if [[ ${_uinfo} =~ @ ]]
  then
    _user="${_uinfo%@*}"
    _password="${_uinfo#*@}"
  else
    _user="${_uinfo}"
  fi
  if [[ ${_password} == "?" ]] || [[ -z ${_password} ]]
  then
    if command -v openssl &>/dev/null
    then
      _printf "Please enter (twice) the new password for user {G}${_user}\n"
      if _password=$(openssl passwd -6)
      then
        _password=$(echo -n "${_password}" | base64 -w 0)
      else
        _abort_script "aborted or not repeated correctly"
      fi
    else
      _abort_script "missinkg openssl tool ( to install: {G}sudo apt-get install -y openssl{N} )"
    fi
  fi
  _config_put "vm/profile/${_runtime[profile]}/user/${_user}" "${_password}"
}

# sudo@socha sudo@other
_config_vm_group_add() {
local _uinfo="$1" _user _group
  if [[ ${_uinfo} =~ @ ]]
  then
    _group="${_uinfo%@*}"
    _user="${_uinfo#*@}"
  else
    _abort_script "missing user for group"
  fi
  _config_put "vm/profile/${_runtime[profile]}/group/${_group}/${_user}"
}

# sudo@socha sudo@other
_config_vm_group_rm() {
local _uinfo="$1" _user _group
  if [[ ${_uinfo} =~ @ ]]
  then
    _group="${_uinfo%@*}"
    _user="${_uinfo#*@}"
  else
    _abort_script "missing user for group"
  fi
  _config_rm "vm/profile/${_runtime[profile]}/group/${_group}/${_user}"
  if [[ -z $(_config_find_all "vm/profile/${_runtime[profile]}/group/${_group}/" key) ]]
  then
    _config_rm "vm/profile/${_runtime[profile]}/group/${_group}"
  fi
}

_config_vm_user_rm() {
  _config_rm "vm/profile/${_runtime[profile]}/user/${1}"
}

_config_vm_generate_ssh_keys() {
local _opt="$1"
  if [[ ${_opt,,} == "off" ]]
  then
    _config_rm "vm/profile/${_runtime[profile]}/generate-ssh-keys"
  elif [[ ${_opt,,} == "on" ]]
  then
    _config_put "vm/profile/${_runtime[profile]}/generate-ssh-keys" "ON"
  else
    _abort_script "ON/OFF is only option supported for generate-ssh-keys"
  fi
}

# socha@~/.ssh/id_rsa.pub
_config_vm_ssh_key_add() {
local _ssh _size _hash _comment _type _rest _enc
local _uinfo="$1" _user _key _info

  if [[ ${_uinfo} =~ @ ]]
  then
    _user="${_uinfo%@*}"
    _key="${_uinfo#*@}"
  else
    _abort_script "missing key location for user"
  fi
  if _ssh=$(_realpath "${_key}")
  then
    if _info=$(ssh-keygen -l -E sha256 -f "${_ssh}")
    then
      read _size _hash _rest <<< "${_info}"
      # parese type and comment
      _rest=$(echo -n "${_rest}" | rev)
      read _type _comment <<< "${_rest}"
      _type=$(echo -n "$_type" | rev)
      _comment=$(echo -n "$_comment" | rev)
      _comment="${_comment%${_type}}"
      _type="${_type::-1}"
      _type="${_type:1}"
      if [[ $_hash =~ ^SHA256 ]]
      then
        # simple encoding
        _hash="${_hash/\//@}"
        _enc=$(base64 -w 0 "${_ssh}")
        _config_put "vm/profile/${_runtime[profile]}/ssh-key/${_user}/${_hash}/key" "${_enc}"
        _config_put "vm/profile/${_runtime[profile]}/ssh-key/${_user}/${_hash}/type" "${_type}"
        _config_put "vm/profile/${_runtime[profile]}/ssh-key/${_user}/${_hash}/comment" "${_comment}"
        _config_put "vm/profile/${_runtime[profile]}/ssh-key/${_user}/${_hash}/size" "${_size}"
        _config_put "vm/profile/${_runtime[profile]}/ssh-key/${_user}/${_hash}/from" "${_key}"
      else
        _abort_script "ssh key {G}%s{N} not usable" "${_key}"
      fi
    else
      _abort_script "unable to load ssh key {G}%s" "${_key}"
    fi
  else
    _abort_script "ssh key file {G}%s{N} not found" "${_key}"
 fi
}

_config_profile_set() {
local _val
  _config_ready
  _runtime[profile]="default"
  if _val=$(_config_get config/default-profile)
  then
    _runtime[profile]="${_val}"
  fi
}

_config_vm() {
  _config_profile_set
  while [[ -n $1 ]]
  do
    case ${1,,} in
      list)
        _config_vm_profile_list
        shift
        ;;
      show)
        _config_vm_profile_show
        shift
        ;;
      get)
        _config_vm_profile_get
        shift
        ;;
      +profile:*|profile:*)
        if [[ -n "${1#*:}" ]]
        then
         _runtime[profile]="${1#*:}"
        else
          _abort_script "missing {G}profile{N} name"
        fi
        shift
        ;;
      -profile:*)
        _config_profile_rm "${1#*:}"
        shift
        ;;
      active|default)
        _config_put "config/default-profile" "${_runtime[profile]}"
        shift
        ;;
      +user:*|user:*)
        _config_vm_user_add "${1#*:}"
        shift
        ;;
      -user:*)
        _config_vm_user_rm "${1#*:}"
        shift
        ;;
      +group:*|group:*)
        _config_vm_group_add "${1#*:}"
        shift
        ;;
      -group:*)
        _config_vm_group_rm "${1#*:}"
        shift
        ;;
      +ssh-key:*|ssh-key:*|+ssh:*|ssh:*)
        _config_vm_ssh_key_add "${1#*:}"
        shift
        ;;
      generate-ssh-keys:*)
        _config_vm_generate_ssh_keys "${1#*:}"
        shift
        ;;
      -ssh-key:*|-ssh:*)
        _config_vm_ssh_key_rm "${1#*:}"
        shift
        ;;
      --verbose|-v)
        VERBOSE=1
        shift
        ;;
      *)
        _abort_script "unknow config option {G}%s\n" "$1"
    esac
  done
}

_mem_info() {
  free -h  --giga -t -w | head -n 2 | cut -c 15-
}

_mem_info_free() {
local _mem _used _free
  read _ _mem _used _free _ <<< $(free -h --giga | tail -n +2 | head -n 1)
  echo -n "${_mem}"
}

_storage_info() {
local _size _avail
  if [[ -n "${1}" ]] && [[ -d "${1}" ]]
  then
    read _size _avail <<< $(df --output=size,avail -h "${1}" | tail -n -1)
    echo -n "${_size}/${_avail}"
  fi
}

_cpu_model() {
local _cpu
  _cpu=$(grep "model name" /proc/cpuinfo | head -n 1)
  echo -n "${_cpu##*: }"
}

_cpu_all_cores() {
local _cores
  _cores=$(grep "model name" /proc/cpuinfo | wc -l)
  echo -n "${_cores}"
}

_cpu_phy_cores() {
local _cores
  _cores=$(cat /proc/cpuinfo | grep "cpu cores" | head -n 1)
  echo -n "${_cores##*: }"
}

_cpu_sockets() {
local _sockets
  _sockets=$(cat /proc/cpuinfo | grep "physical id" | sort | uniq | wc -l)
  echo -n "${_sockets}"
}

_config_host_remote_info() {
  _ssh "${_runtime[host]}" -c info
}

_config_host_info() {
local _socket _cpu _cores _all_cores
  _socket=$(_cpu_sockets)
  _cpu=$(_cpu_model)
  _cores=$(( ${_socket} * $(_cpu_phy_cores)))
  _all_cores=$(_cpu_all_cores)
  echo "CPU: ${_socket} x ${_cpu} ( ${_cores} / ${_all_cores} )"
  echo "STORAGE: $(_storage_info ${VM_STORAGE})"
  echo "MEMORY:"
  _mem_info
  echo "UPTIME:" $(uptime)
}

_config_host() {
local _val
  _config_ready
  while [[ -n $1 ]]
  do
    case ${1,,} in
      list|--list)
        _config_host_list
        shift
        ;;
      show)
        if _require_runtime host
        then
            _config_host_show
        else
          _abort_script "missing {G}host{N} name (required for {Y}show)"
        fi
        shift
        ;;
      ssh)
        shift
        if _require_runtime host
        then
            _ssh --pass -t "${_runtime[host]}" "$@"
            exit
        else
          _abort_script "missing {G}host{N} name (required for {Y}ssh)"
        fi
        ;;
      show:*|show::*)
        if _require_runtime host
        then
          if _val=$(_extract_param "${1}")
          then
            _config_host_show_key "${_val}"
          else
            _abort_script "missing {G}key{N} for {Y}show::*"
          fi
        else
          _abort_script "missing {G}host{N} name (required for {Y}show::*)"
        fi
        shift
        ;;
      get:uri|get::uri)
        if _require_runtime host
        then
          _print_line $(_vm_host_uri "${_runtime[host]}")
        else
          _abort_script "missing {G}host{N} name (required for {Y}show::*)"
        fi
        shift
        ;;
      +auth:*|auth:*)
        if _require_runtime host
        then
            _config_host_auth "${1#*:}"
        else
          _abort_script "missing {G}host{N} name (required for {Y}auth)"
        fi
        shift
        ;;
      +key:*|key:*|-key)
        if _require_runtime host
        then
          if [[ ${1} =~ : ]]
          then
            _config_host_key "${1#*:}"
          else
            _config_host_key
          fi
        else
          _abort_script "missing {G}host{N} name (required for key)"
        fi
        shift
        ;;
      +user:*|user:*|-user)
        if _require_runtime host
        then
          if [[ ${1} =~ : ]]
          then
            _config_host_user "${1#*:}"
          else
            _config_host_user
          fi
        else
          _abort_script "missing {G}host{N} name (required for user)"
        fi
        shift
        ;;
      info)
        if _require_runtime host
        then
          _config_host_remote_info
        else
          _config_host_info
        fi
        shift
        ;;
      +port:*|port:*|-port)
        if _require_runtime host
        then
          if [[ ${1} =~ : ]]
          then
            _config_host_port "${1#*:}"
          else
            _config_host_port
          fi
        else
          _abort_script "missing {G}host{N} name (required for port)"
        fi
        shift
        ;;
      +host:*|host:*)
        _config_host_add "${1#*:}"
        shift
        ;;
      -host:*)
        _config_host_rm "${1#*:}"
        shift
        ;;
      +me:*|me:*|-me)
        if [[ ${1} =~ : ]]
        then
          _config_put "config/me" "${1#*:}"
        else
          _config_rm "config/me"
        fi
        shift
        ;;
      +disable:local|disable:local)
        _config_put "config/disable-local" "1"
        shift
        ;;
      -disable:local)
        _config_rm "config/disable-local"
        shift
        ;;
      bridge:*)
        _config_put "config/bridge" "${1#*:}"
        shift
        ;;
      address:*|+address:*|-address)
        if _require_runtime host
        then
          if [[ ${1} =~ : ]]
          then
            _config_host_address "${1#*:}"
          else
            _config_host_address
          fi
        else
          _abort_script "missing {G}host{N} name (required for address)"
        fi
        shift
        ;;
      --verbose|-v)
        VERBOSE=1
        shift
        ;;
      *)
        _abort_script "unknow config option {G}%s\n" "$1"
    esac
  done
}

_config_template_location() {
local _templates
  if _templates=$(_config_get "config/templates")
  then
    echo "${_templates}"
  else
    echo "$HOME/vm/template"
  fi
}

_config_storage_location() {
local _vm_storage
  if _vm_storage=$(_config_get "config/storage")
  then
    echo "${_vm_storage}"
  else
    echo "$HOME/vm/rskvm"
  fi
}

_config_default_bridge() {
local _bridge
  if _bridge=$(_config_get "config/bridge")
  then
    export BRIDGE="${_bridge}"
  else
    if ip -o link show dev rskvm0 &>/dev/null
    then
      _verbose_printf "Autoselecting default bridge: {G}rskvm0\n"
      _config_put "config/bridge" "rskvm0"
      export BRIDGE="rskvm0"
    elif ip -o link show dev lan0 &>/dev/null
    then
      _verbose_printf "Autoselecting default bridge: {G}lan0\n"
      _config_put "config/bridge" "lan0"
      export BRIDGE="lan0"
    elif ip -o link show dev virbr0 &>/dev/null
    then
      _verbose_printf "Autoselecting default bridge: {G}virbr0\n"
      _config_put "config/bridge" "virbr0"
      export BRIDGE="virbr0"
    else
      _abort_script "Unable to locate default bridge device"
    fi
  fi
}

_ssh() {
local _addr _user _default _auth _tmp _key _port _pass=0
  if [[ ${1} == "--pass" ]]
  then
    shift
    _pass=1
  fi
  _default="-T -o LogLevel=QUIET -o ConnectTimeout=20"
  while [[ ${1} =~ ^- ]]
  do
    _default="${_default} ${1}"
    shift
  done
  _default="${_default} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  if _tmp=$(_config_get "/host/${1}/auth")
  then
    if [[ $_tmp == "key" ]]
    then
      if _key=$(_config_get "/host/${1}/key")
      then
        _default="${_default} -i ${_key} -o IdentitiesOnly=yes"
      fi
    fi
  fi
  if _user=$(_config_get "/host/${1}/user")
  then
    _default="${_default} -l ${_user}"
  fi
  if ! _port=$(_config_get "/host/${1}/port")
  then
    _port="22"
  fi
  _default="${_default} -p ${_port}"
  _addr=$(_config_get_host "${1}")
  shift
  if [[ ${_pass} -eq 0 ]]
  then
    if [[ ${VERBOSE} -eq 1 ]]
    then
      echo "ssh ${_default} ${_addr} -- $ME $@" >>~/.rskvm.log
    fi
    ssh ${_default} ${_addr} -- $ME $@
  else
    if [[ ${VERBOSE} -eq 1 ]]
    then
      echo "ssh ${_default} ${_addr} -- $@" >>~/.rskvm.log
    fi
    ssh ${_default} ${_addr} -- $@
  fi
}

_pull_image() {
local _template=$1 _hash=$2 _url
  if ! _url=$(_config_get "image/alias/by-hash/${_hash}/url")
  then
    _vm_update_images_quiet
  fi
  if _url=$(_config_get "image/alias/by-hash/${_hash}/url")
  then
    if curl --connect-timeout "${CURL_TIMEOUT}" -sIf -o /dev/null "${_url}"
    then
      _verbose_printf "Retrieving image template {G}%s{N} from {Y}%s\n" "${_template}" "${_url}"
      if [[ -f ${TEMPLATES}/${_template} ]]
      then
        _abort_script "obsolete image template present"
      fi
      if [[ ! -d ${TEMPLATES}/${_template} ]]
      then
        mkdir -p "${TEMPLATES}/${_template}"
      fi
      if [[ ! -d ${TEMPLATES}/${_template} ]]
      then
        _abort_script "unable to create image template directory at {Y}%s" "${TEMPLATES}/${_template}/"
      fi
      _printf "{R}{N}"
      if curl --connect-timeout "${CURL_TIMEOUT}" -#f "${_url}" | xzcat --uncompress --to-stdout --single-stream  | dd of="${TEMPLATES}/${_template}/${_hash}.download" status=none
      then
        mv "${TEMPLATES}/${_template}/${_hash}.download" "${TEMPLATES}/${_template}/${_hash}"
        _printf "{G}"
        _verbose_printf "Image {G}%s{N}/{G}%s{N} retrieved successfully!\n" "${_template}" "${_hash}"
      else
        _verbose_printf "{Y}WARNING: {N}unable to retrive image {G}%s {N}from {Y}url{N}\n" "${_template}" "${_url}"
      fi
    else
      _verbose_printf "{Y}WARNING: {N}unable to locate image {G}%s {N}at {Y}url{N}\n" "${_template}" "${_url}"
    fi
  else
    _verbose_printf "{Y}WARNING: {N}no {G}url{N} for image {Y}%s{N} definied!\n" "${_template}"
  fi
}

vm_config() {
local _config _name=$1
  if [[ -n "${_X_SOCHA_PROFILE}" ]]
  then
    _config="${_X_SOCHA_PROFILE}"
  else
    _config=$(_config_vm_profile_get)
  fi
  if [[ ! $_config =~ ^kvm-cnf-no-net! ]]
  then
    _config="kvm-cnf-no-net"
  fi
  if [[ -z ${_name} ]]
  then
    _abort_script "empty vm name given"
  fi
  _config="${_config}!name:${_name}"
  echo "${_config}"
}

vm_create() {
local _name="${1}" _template="${2}" _ram=${3} _cpu=${4} _opts="${5}" _hash="${6}"
local _os _variant _info _storage_bus
local _template_file _template_image _template_format
local _params
  _check_local_access
  if [[ -z ${VM_STORAGE} ]]
  then
    _abort_script "missing {G}VM_STORAGE{N} env!"
  fi
  if [[ -z ${BRIDGE} ]]
  then
    _abort_script "missing {G}BRIDGE{N} env!"
  fi
  if [[ -z ${TEMPLATES} ]]
  then
    _abort_script "missing {G}TEMPLATES{N} env!"
  fi
  if [[ ! -d ${TEMPLATES} ]]
  then
    _verbose_printf "Creating virtual machine template directory at {G}%s\n" "${TEMPLATES}"
    mkdir -p "${TEMPLATES}"
  fi
  if [[ ! -d ${TEMPLATES} ]]
  then
    _abort_script "unable to create {G}template{N} directory at {Y}%s" "${TEMPLATES}"
  fi
  if [[ ! -d ${VM_STORAGE} ]]
  then
    _verbose_printf "Creating virtual machine storage directory at {G}%s\n" "${VM_STORAGE}"
    mkdir -p "${VM_STORAGE}"
  fi
  if [[ ! -d ${VM_STORAGE} ]]
  then
    _abort_script "unable to create {G}vm storage{N} directory at {Y}%s" "${VM_STORAGE}"
  fi
  if LANG=C virsh dominfo "${_name}" &>/dev/null
  then
    _abort_script "virtual machine with {G}%s{N} name already exist!" "${_name}"
  fi
  if [[ -f ${VM_STORAGE}/${_name}.vm ]]
  then
    _abort_script "disk image for {G}%s {N}already exists!" "${_name}"
  fi
  if [[ -z ${_hash} ]]
  then
    if ! _hash=$(_config_get "image/master/${_template}/hash")
    then
      _abort_script "unable to locate {G}hash{R} for template {Y}%s" "${_template}"
    fi
  fi
  _template_file="${TEMPLATES}/${_template}/${_hash}"
  if [[ ! -f ${_template_file} ]]
  then
    _verbose_printf "Looking for image template {G}%s{N}/{G}%s{N} at {Y}%s\n" "${_template}" "${_hash}" "${KVMREPO}"
    _pull_image "${_template}" "${_hash}"
  fi
  if [[ ! -f ${_template_file} ]]
  then
    _abort_script "unable to locate template image {G}%s{N}/{G}%s{N} at {Y}%s" "${_template}" "${_hash}" "${TEMPLATES}"
  fi
  if ! _os=$(_config_get "image/master/${_template}/os")
  then
    _os="linux"
  fi
  if ! _variant=$(_config_get "image/master/${_template}/variant")
  then
    _variant="generic"
  fi
  if ! _storage_bus=$(_config_get "image/master/${_template}/storage_bus")
  then
    _storage_bus="virtio"
  fi
  if ! _info=$(_config_get "image/master/${_template}/info")
  then
    _info="UNKNOW"
  fi
  _verbose_printf "{G}%s{N}@{G}%s{N}\n  TEMPLATE: {Y}%s{N}\n  TYPE: {Y}%s{N}\n  VARIANT: {Y}%s{N}\n  RAM: {Y}%s{N}\n  CPU: {Y}%s{N}\n" "${_name}" "$(_who_am_i)" "${_template}" "${_os}" "${_variant}" "${_ram}" "${_cpu}"

  _params=()
  _params+=( --name "${_name}" )
  _params+=( --os-variant "${_variant}" )
  _params+=( --memory "${_ram}" )
  _params+=( --vcpus sockets=1,threads=1,cores=${_cpu} )
  _params+=( --disk "path=${VM_STORAGE}/${_name}.vm,bus=${_storage_bus},cache=writeback" )
  _params+=( --network "bridge=$BRIDGE,model=virtio" )
  _params+=( --metadata title="$_name / ${_info}" )
  _params+=( --graphics spice,image.compression=auto_glz )
  _params+=( --channel unix,target_type=virtio,name=org.qemu.guest_agent.0 )

  if [[ ! ${_opts} =~ :noconfig: ]]
  then
    if ! _config=$(vm_config "${_name}")
    then
      _abort_script "unable to prepare virtual machine cloud config!"
    fi
    _params+=( --sysinfo "oemStrings.entry0=${_config}" )
    _params+=( --sysinfo "oemStrings.entry1='kvm-cnf-net!dns-registry:registry.dns.vm'" )
  fi

  if [[ ${_opts} =~ :full: ]]
  then
    _params+=( --metadata description="$ME / ${_template} / full-clone" )
    _verbose_printf "Cloning image {G}%s{N} to {Y}%s\n" "${_template}/${_hash}" "${_name}.vm"
    qemu-img convert -q -f qcow2 -O qcow2 "${_template_file}" "${VM_STORAGE}/${_name}.vm"
  else
    _params+=( --metadata description="$ME / ${_template} / link-clone" )
    _verbose_printf "Linking image {G}%s{N} to {Y}%s\n" "${_template}/${_hash}" "${_name}.vm"
    qemu-img create -q -f qcow2 -F qcow2 -b "${_template_file}" "${VM_STORAGE}/${_name}.vm"
  fi
  if [[ ${_opts} =~ :nested: ]]
  then
    _params+=( --cpu mode=host-passthrough,disable=hypervisor )
  else
    _params+=( --cpu mode=host-passthrough )
  fi
  _params+=( --hvm --virt-type kvm --noautoconsole --import --quiet )
  virt-install "${_params[@]}"
  _verbose_printf "{G}%s {Y}created successfully!\n" "${_name}"
}

_extract_param() {
local _param="${1}"
  while [[ ${_param} =~ : ]]
  do
    _param="${_param#*:}"
  done
  if [[ -n ${_param} ]]
  then
    echo -n "${_param}"
    return 0
  fi
  return 1
}

_parse_host() {
local _name="${1}" _host _local
  if [[ -z "${_name}" ]]
  then
    return
  fi
  if [[ ${_name} =~ @ ]]
  then
    _host="${_name##*@}"
  else
    _host="${_name}"
  fi
  if [[ ${_host} =~ : ]]
  then
    _host="${_host%%:*}"
  fi
  if _local=$(_config_get "config/me")
  then
    if [[ ${_local} != ${_host} ]]
    then
      echo "${_host}"
    fi
  else
    if [[ ${_host} != $(_who_am_i) ]] && [[ ${_host} != $(hostname) ]]
    then
      echo "${_host}"
    fi
  fi
}

_vm_get_ip4_addr() {
local _name="${1}" _info _mac _bridge _ip
  if ! _bridge=$(_config_get "config/bridge")
  then
    _config_default_bridge
    _bridge=$BRIDGE
  fi
  if _mac=$(LANG=C virsh domiflist "${_name}" 2>/dev/null | fgrep "${_bridge}" | egrep -i -o '([a-f0-9][a-f0-9]:){5}[a-f0-9][a-f0-9]')
  then
    if _info=$(LANG=C virsh domifaddr --domain "${_name}" --full --source=agent 2>/dev/null | fgrep -i "${_mac}" | fgrep -i ipv4 | egrep -o "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+")
    then
      for _ip in ${_info}
      do
        if [[ -n ${_ip} ]] && [[ ! ${_ip} =~ ^169\.254 ]]
        then
          echo -n "${_ip}"
          break
        fi
      done
    fi
  fi
}

_check_local_access() {
local _val
  if _val=$(_config_get "config/disable-local")
  then
    _abort_script "local operations on this host aren't supported!"
  fi
}

_list_all_vm() {
local _host _quiet="${1}"
  for _host in $(_config_find_all host tree)
  do
    if ! _list_vm ${_quiet} "@${_host}"
    then
      :
    fi
  done
}

_list_vm() {
local _uuid _list _desc _state _title _os _color _protected _name _me _quiet="${1}" _host _ip _val _q
  shift
  if [[ "${1}" == "@" ]] && [[ ${IS_REMOTE} -eq 0 ]]
  then
    _list_all_vm "${_quiet}"
    return 0
  fi
  if [[ ${IS_REMOTE} -eq 0 ]]
  then
    _host=$(_parse_host "${1}")
    if [[ -n ${_host} ]]
    then
      if [[ ${_quiet} == "1" ]]
      then
        _q="--lq"
      else
        _q="--list"
      fi
      if ! _ssh "${_host}" --remote ${_q}
      then
        if [[ ${_quiet} -eq 0 ]]
        then
          _printf "{Y}WARNING{N}: connection to {G}%s{N} failed!\n" "${_host}"
        fi
        #_abort_script "connection to {G}%s{N} failed!" "${_host}"
      fi
      return
    else
      _check_local_access
    fi
  fi
  _me=$(_who_am_i)
  _list=$(virsh list --all --uuid)
  for _uuid in ${_list}
  do
    _desc=$(LANG=C virsh desc "${_uuid}")
    if [[ ! ${_desc} =~ rskvm ]]
    then
      continue
    fi
    if _is_vm_hidden "${_uuid}"
    then
      continue
    fi
    _protected=0
    if _is_vm_protected "${_uuid}"
    then
      _protected=1
    fi
    _name=$(LANG=C virsh domname "${_uuid}")
    _name="${_name}@${_me}"
    if [[ ${_quiet} == "1" ]]
    then
      printf "%s\n" "${_name}"
    else
      _state=$(LANG=C virsh domstate "${_uuid}")
      _title=$(LANG=C virsh desc --title "${_uuid}")
      if [[ ${_title} =~ / ]]
      then
        _os="${_title#*/ }"
        _title="${_title% /*}"
      else
        _os=""
      fi
      _ip="-"
      case "${_state,,}" in
        running)
          _color="{G}"
          _ip=$(_vm_get_ip4_addr "${_uuid}")
          if [[ -z ${_ip} ]]
          then
            _ip="retrieving"
          fi
          ;;
        "in shutdown")
          _color="{C}"
          _state="stopping"
          ;;
        "shut off")
          _color="{R}"
          _state="stopped"
          ;;
        *)
          _color="{N}"
      esac
      if [[ ${_protected} -eq 1 ]]
      then
        _printf "${_color}%-9s{N}" "${_state}"
        _printf "{R}+{Y}%-40s{C}%-16s{N}%s\n" "${_name}" "${_ip}"  "${_os}"
      else
        _printf "${_color}%-10s{N}" "${_state}"
        _printf "{Y}%-40s{C}%-16s{N}%s\n" "${_name}" "${_ip}" "${_os}"
      fi
    fi
  done
}

_check_catalog_present() {
local _var _name
  for _name in $@
  do
    _var="_${_name}"
    if [[ -z ${!_var+x} ]]
    then
      if [[ -z ${_image+x} ]]
      then
        _abort_script "missing catalog definition for parameter {G}${_name}"
      else
        _abort_script "missing catalog definition for parameter {G}${_name}{N} for image {Y}${_image}"
      fi
    fi
  done
}
_vm_update_images_quiet() {
local _verbose
  _verbose="${VERBOSE}"
  VERBOSE=0
  _vm_update_images
  VERBOSE="${_verbose}"
}

# build image list
_vm_update_images() {
local _catalog _entry _image _format _os _variant _images _aliases _alias _info _default _storage_bus _hash _wait _ram _cpu
  # images are already refresehd in this session
  if [[ ${_IMAGE_REFRESHED} -eq 1 ]]
  then
    return 0
  fi
  _config_rm "/image"
  _config_put "/image/version" "1"
  declare -A _images
  if curl --connect-timeout "${CURL_TIMEOUT}" -sIf -o /dev/null "${KVMREPO}/catalog"
  then
    if _catalog=$(curl --connect-timeout "${CURL_TIMEOUT}" -sf "${KVMREPO}/catalog")
    then
      _image=""
      set -- ${_catalog}
      while [[ -n "${1}" ]]
      do
        case "${1}" in
          image:*)
            # Default storage bus
            _storage_bus="virtio"
            _image="${1#*:}"
            _check_catalog_present image
            unset _format _os _variant _aliases _info _hash
            _images[${_image}]="${_image}"
            _config_put "image/master/${_image}/image" "${_image}"
            ;;
          info:*)
            _info="${1#*:}"
            _check_catalog_present image info
            _info="${_info//+/ }"
            _config_put "image/master/${_image}/info" "${_info}"
            ;;
          format:*)
            _format="${1#*:}"
            _check_catalog_present image format
            _config_put "image/master/${_image}/format" "${_format}"
            ;;
          os:*)
            _os="${1#*:}"
            _check_catalog_present image os
            _config_put "image/master/${_image}/os" "${_os}"
            ;;
          variant:*)
            _variant="${1#*:}"
            _check_catalog_present image variant
            _config_put "image/master/${_image}/variant" "${_variant}"
            ;;
          storage-bus:*)
            _storage_bus="${1#*:}"
            _check_catalog_present image
            _config_put "image/master/${_image}/storage_bus" "${_storage_bus}"
            ;;
          hash:*)
            _hash="${1#*:}"
            _check_catalog_present image
            _verbose_printf "image {G}%s{N} / {M}%s{N} updated\n" "${_image}" "${_hash}"
            _config_put "image/master/${_image}/hash" "${_hash}"
            _config_put "image/master/${_image}/url" "${KVMREPO}/image/${_image}/${_hash}"
            ;;
          ram:*)
            _ram="${1#*:}"
            if [[ ${_ram} =~ ^[0-9]+$ ]]
            then
              _check_catalog_present image
              _config_put "image/master/${_image}/ram" "${_ram}"
            else
              _abort_script "unable to parse {G}ram{R} option for image {Y}${_image}"
            fi
            ;;
          cpu:*)
            _cpu="${1#*:}"
            if [[ ${_cpu} =~ ^[0-9]+$ ]]
            then
              _check_catalog_present image
              _config_put "image/master/${_image}/cpu" "${_cpu}"
            else
              _abort_script "unable to parse {G}cpu{R} option for image {Y}${_image}"
            fi
            ;;
          wait:*)
            _wait="${1#*:}"
            if [[ ${_wait} =~ ^[0-9]+:([0-9]*[.])?[0-9]+:[0-9]+$ ]]
            then
              _check_catalog_present image
              _config_put "image/master/${_image}/wait_params" "${_wait}"
            else
              _abort_script "unable to parse {G}wait{R} option for image {Y}${_image}"
            fi
            ;;
          alias:*)
            _aliases="${1#*:}"
            _check_catalog_present image variant aliases os variant format info storage_bus hash
            for _alias in ${_aliases//,/ }
            do
              if [[ -z ${_alias} ]]
              then
                continue
              fi
              if [[ -n ${_images[${_alias}]} ]]
              then
                _abort_script "image alias {G}${_alias} {N}is already defined for image {Y}${_images[${_alias}]}"
              fi
              _images[${_alias}]="${_image}"
              _config_link "image/master/${_image}" "image/alias/by-image/${_image}/${_alias}"
              _config_link "image/master/${_image}" "image/alias/by-name/${_alias}"
              _config_link "image/master/${_image}" "image/alias/by-hash/${_hash}"
              _verbose_printf "  alias {Y}%s{N}\n" "${_alias}"
            done
            ;;
          *)
            _printf "{Y}WARNING: {N}unknow catalog option {G}${1}\n"
        esac
        shift
      done
      if _default=$(_config_get config/default-image)
      then
        if [[ -z ${_images[${_default}]} ]]
        then
          _verbose_printf "removing missing default image {G}${_default}\n"
          _config_rm config/default-image
        fi
      fi
      if ! _default=$(_config_get config/default-image)
      then
        # set new default image
        for _image in ${PREFERED_TEMPLATE[@]}
        do
          if [[ -n ${_images[${_image}]} ]]
          then
            _verbose_printf "Auto selecting default image {G}${_image}{N}.\n"
            _config_put "config/default-image" "${_image}"
            break
          fi
        done
      fi
      if ! _default=$(_config_get config/default-image)
      then
        _printf "{Y}WARNING: {N}no defualt template set!\n"
      fi
      _IMAGE_REFRESHED=1
    else
      _abort_script "unable to retrive image catalog"
    fi
  fi
}

_vm_flush_images() {
local _image _same _list _host _remote
  abort_script "_vm_flush_images() refactor me!"
  if [[ ${IS_REMOTE} -eq 0 ]]
  then
    _host=$(_parse_host "${1}")
    if [[ -n ${_host} ]]
    then
      _remote=" "
      if [[ $VERBOSE -eq 1 ]]
      then
        _remote=" --verbose "
      fi
      if [[ $FORCE -eq 1 ]]
      then
        _remote="${_remote}--force "
      fi
      if ! _ssh "${_host}" --remote${_remote}--flush-templates
      then
        _abort_script "connection to {G}%s{N} failed!" "${_host}"
      fi
      return
    else
      _check_local_access
    fi
  fi
  _list=$(_config_find_all image tree)
  for _image in ${_list}
  do
    if _same=$(_config_get "image/${_image}/image")
    then
      if [[ ${_same} == ${_image} ]]
      then
        if [[ -f ${TEMPLATES}/${_image} ]]
        then
          _verbose_printf "Cleaning image {G}%s{N} from {Y}%s/%s\n" "${_image}" "${TEMPLATES}" "${_image}"
          if [[ $FORCE -eq 1 ]]
          then
            if rm -f "${TEMPLATES}/${_image}" 2>/dev/null
            then
              _verbose_printf "Image {G}%s{N} removed.\n" "${_image}"
            else
              _printf "{Y}WARNING: {N}unable to remove image {G}%s\n" "${_image}"
            fi
          else
            _abort_script "make sure you know what you doing! use {G}--force{N} to confirm!"
          fi
        fi
      fi
    fi
  done
}

_vm_list_images() {
local _image _same _aliases _alias _list _default _def_ind
  _default=$(_config_get config/default-image) || true
  _list=$(_config_find_all image/master tree | sort)
  for _image in ${_list}
  do
    if [[ ${_default} == ${_image} ]]
    then
      _printf " {R}${_image} {C}(%s / %s)\n" "$(_config_get image/master/${_image}/os)" "$(_config_get image/master/${_image}/info)"
    else
      _printf " {G}${_image} {C}(%s / %s)\n" "$(_config_get image/master/${_image}/os)" "$(_config_get image/master/${_image}/info)"
    fi
    _aliases=$(_config_find_all "image/alias/by-image/${_image}" tree | sort)
    if [[ -n ${_aliases} ]]
    then
      _printf "   "
      for _alias in ${_aliases}
      do
        _printf "{Y}${_alias} "
      done
      _printf "\n"
    fi
  done
}

_vm_set_default_image() {
local _image=$1 _val _tmp
  if ! _val=$(_config_get "image/master/${_image}/image")
  then
    _vm_update_images_quiet
  fi
  if _val=$(_config_get "image/master/${_image}/image")
  then
    _verbose_printf "Setting up {G}${_val}{N} as the default image.\n"
    _config_put "config/default-image" "${_val}"
  else
    _abort_script "unable to set {G}${_image}{N} as default image!\n"
  fi
}

# [?+-^]name[/template][@host][:ram][:cpu] [host:name] [template:name] [ram:N] [cpu:N] [name:vm-name] [do:delete|create|query]
_vm_parse_spec() {
local _cmd _tmp
local _do _host _ram _cpu _template _name
local _rest=()
  _do="$1"
  shift
  if [[ -n "${1}" ]]
  then
    _cmd="${1}"
    if [[ ${_cmd::1} == "-" ]]
    then
      _cmd="${_cmd:1}"
      if [[ -z ${_do} ]] || [[ ${_do} == "delete" ]]
      then
        _do="delete"
      else
        _abort_script "other action selected: {Y}%s" "${_do}"
      fi
    elif [[ ${_cmd::1} == "+" ]]
    then
      _cmd="${_cmd:1}"
      if [[ -z ${_do} ]] || [[ ${_do} == "create-wait" ]] || [[ ${_do} == "create" ]]
      then
        _do="create-wait"
      else
        _abort_script "other action selected: {Y}%s" "${_do}"
      fi
    elif [[ ${_cmd::1} == "^" ]]
    then
      _cmd="${_cmd:1}"
      if [[ -z ${_do} ]] || [[ ${_do} == "exists" ]]
      then
        _do="exists"
      else
        _abort_script "other action selected: {Y}%s" "${_do}"
      fi
    elif [[ ${_cmd::1} == "." ]] || [[ ${_cmd::1} == "?" ]]
    then
      _cmd="${_cmd:1}"
      if [[ -z ${_do} ]] || [[ ${_do} == "query" ]]
      then
        _do="query"
      else
        _abort_script "other action selected: {Y}%s" "${_do}"
      fi
    else
      if [[ -z ${_do} ]]
      then
        _do="create"
      fi
    fi
    if [[ ${_cmd} =~ @ ]]
    then
      _name="${_cmd%%@*}"
      _host="${_cmd##*@}"
      _host="${_host%%:*}"
      _cmd="${_cmd##*@}"
    else
      _host="localhost"
      _name="${_cmd%%:*}"
    fi
    if [[ ${_cmd} =~ : ]]
    then
      _tmp="${_cmd%%:*}"
      _cmd="${_cmd#${_tmp}}"
    else
      _cmd=""
    fi
    if [[ ${_name} =~ / ]]
    then
      _template="${_name##*/}"
      _name="${_name%%/*}"
    fi

    # ram/cpu
    if [[ ${_cmd} =~ ^: ]]
    then
      _ram="${_cmd#*:}"
      _cmd="${_ram}"
      _ram="${_ram%%:*}"
      _cmd="${_cmd#${_ram}}"
      if [[ ${_cmd} =~ ^: ]]
      then
        _cpu="${_cmd##*:}"
      fi
    fi
  fi
  # Verify
  if [[ -z ${_ram} ]]
  then
    _ram=0
  fi
  if [[ -z ${_cpu} ]]
  then
    _cpu=0
  fi
  if [[ ! ${_do} =~ ^(delete|create|create-wait|query|start|stop|console|viewer|guard|protect|unguard|unprotect|hide|unhide|exists|commit)$ ]]
  then
    _abort_script "unknow {G}action{N}: {Y}${_do}"
  fi
  if [[ ${#_name} -lt 2 ]]
  then
    _abort_script "name {G}%s{N} too short!" "${_name}"
  fi
  if [[ ${#_name} -gt 63 ]]
  then
    _abort_script "name {G}%s{N} too long!" "${_name}"
  fi
  if ! _verify_name "${_name}"
  then
    _abort_script "incorrect name: {Y}%s {N}allowed characters: {Y}[a-z0-9][a-z0-9-]*[a-z0-9]" "${_name}"
  fi
  if ! _verify_hostname "${_host}"
  then
    _abort_script "incorrect hostname: {Y}%s" "${_host}"
  fi
  if [[ ! ${_ram} =~ ^[0-9]+$ ]]
  then
    _abort_script "invalid RAM size specified: {Y}%s" "${_ram}"
  fi
  if [[ ! ${_cpu} =~ ^[0-9]+$ ]]
  then
    _abort_script "invalid CPU count specified: {Y}%s" "${_cpu}"
  fi
  if [[ -n "${_template}" ]]
  then
    if ! _val=$(_config_get "image/master/${_template}/image")
    then
      if ! _val=$(_config_get "image/alias/by-name/${_template}/image")
      then
        _vm_update_images_quiet
      fi
    fi
    if _val=$(_config_get "image/master/${_template}/image")
    then
      _template="${_val}"
    else
      if _val=$(_config_get "image/alias/by-name/${_template}/image")
      then
        _template="${_val}"
      else
        _abort_script "unknown template {G}%s{N} selected!" "$_template"
      fi
    fi
  else
    if ! _template=$(_config_get "config/default-image")
    then
      _vm_update_images_quiet
    fi
    if ! _template=$(_config_get "config/default-image")
    then
      _abort_script "no tempalate selected and no default template set!"
    fi
    if _val=$(_config_get "image/master/${_template}/image")
    then
      _template="${_val}"
    else
      if _val=$(_config_get "image/alias/by-name/${_template}/image")
      then
        _template="${_val}"
      else
        _abort_script "unknown template {G}%s{N} selected!" "$_template"
      fi
    fi
  fi

  if [[ $_ram -eq 0 ]]
  then
    if ! _ram=$(_config_get "/image/master/${_template}/ram")
    then
      _ram="${DEFAULT_RAM}"
    fi
  fi
  if [[ $_ram -le 128 ]]
  then
    _ram="$((${_ram} << 10))"
  fi

  if [[ $_cpu -eq 0 ]]
  then
    if ! _cpu=$(_config_get "/image/master/${_template}/cpu")
    then
      _cpu="${DEFAULT_CPU}"
    fi
  fi
  if [[ $_cpu -gt 32 ]] && [[ $FORCE -eq 0 ]]
  then
    _abort_script "CPU count greater than {G}32{N} - use {Y}--force{N} to confirm!"
  fi
  if [[ $_ram -gt 65536 ]] && [[ $FORCE -eq 0 ]]
  then
    _abort_script "RAM size greater than {G}64GB{N} - use {Y}--force{N} to confirm!"
  fi

  export RSKVM_DO="${_do}"
  export RSKVM_NAME="${_name}"
  export RSKVM_TEMPLATE="${_template}"
  export RSKVM_RAM="${_ram}"
  export RSKVM_CPU="${_cpu}"
  export RSKVM_HOST="${_host}"
}

_who_am_i() {
local _me
  if _me=$(_config_get "/config/me")
  then
    echo -n "${_me}"
  else
    echo -n "$(hostname)"
  fi
}
_vm_wait_for_me() {
local _name="${1}" _host="${2}" _template="${3}" _wait_params _ip _done=0 _cnt=0 _wait_count _wait_sleep _wait_progress
  _wait_params=$(_config_get "/image/master/${_template}/wait_params") || true
  if [[ ${_wait_params} =~ ^[0-9]+:([0-9]*[.])?[0-9]+:[0-9]+$ ]]
  then
    IFS=":" read _wait_count _wait_sleep _wait_progress  <<< "${_wait_params}"
  else
    _wait_count=180
    _wait_sleep=0.25
    _wait_progress=4
  fi
  _printf "{G}%s{N}@{Y}%s{N} " "${_name}" "${_host}"
  while [[ ${_done} -eq 0 ]]
  do
    _ip=$(_vm_get_ip4_addr "${_name}")
    if [[ -n ${_ip} ]]
    then
      _done=1
    else
      if [[ ${_cnt} -gt ${_wait_count} ]]
      then
        _done=1
      else
        if [[ $((${_cnt} % ${_wait_progress})) -eq 0 ]]
        then
          _printf "{R}."
        fi
        sleep "${_wait_sleep}"
      fi
    fi
    ((_cnt++)) || true
  done
  if [[ -n ${_ip} ]]
  then
    _printf " {Y}%s\n" "${_ip}"
  else
    _printf " {Y}TIMEOUT\n"
  fi
}

_is_vm_hidden() {
local _name="${1}"
  if virsh metadata --config --domain "${_name}" --uri "${NSURI}hide" &>/dev/null
  then
    return 0
  fi
  return 1
}

_is_vm_protected() {
local _name="${1}"
  if virsh metadata --config --domain "${_name}" --uri "${NSURI}protect" &>/dev/null
  then
    return 0
  fi
  return 1
}

_is_vm_exists() {
local _name="${1}" _desc
  if [[ -n "${_name}" ]]
  then
    if _desc=$(LANG=C virsh desc "${_name}" 2>/dev/null)
    then
      if [[ ${_desc} =~ rskvm ]]
      then
        return 0
      fi
    fi
  fi
  return 1
}

_vm_commit_backing() {
local _vm="${1}" _disk _other
  if _is_vm_exists "${_vm}"
  then
    _vm_start "${_vm}"
    virsh domblklist "${_vm}" | tail -2 | egrep . | while read _disk _other
    do
      _printf "Comitting {G}%s{N} on {Y}%s\n" "${_disk}" "${_vm}"
      virsh blockpull --domain "${_vm}" "${_disk}" --wait --verbose
    done
  else
    _abort_script "no such vm {G}%s" "${_vm}"
  fi
}

_vm_protect() {
local _name="${1}" _desc
  if [[ -n "${_name}" ]]
  then
    if ! _desc=$(LANG=C virsh desc "${_name}" 2>/dev/null)
    then
      _abort_script "virtual machine {G}%s{N} not found" "${_name}"
    fi
    if [[ ! ${_desc} =~ rskvm ]]
    then
      _abort_script "virtual machine not supported by $ME"
    fi
    _verbose_printf "Setting protected state on {G}%s{N}.\n" "${_name}"
    if ! LANG=C virsh metadata --config --domain "${_name}" --uri "${NSURI}protect" --key 'rskvm-protect' --set '<enable/>' &>/dev/null
    then
      _abort_script "Unable to set protected state on {G}%s{N}..." "${_name}"
    fi
  fi
}

_vm_unprotect() {
local _name="${1}" _desc
  if [[ -n "${_name}" ]]
  then
    if ! _desc=$(LANG=C virsh desc "${_name}" 2>/dev/null)
    then
      _abort_script "virtual machine {G}%s{N} not found" "${_name}"
    fi
    if [[ ! ${_desc} =~ rskvm ]]
    then
      _abort_script "virtual machine not supported by $ME"
    fi
    _verbose_printf "Setting unprotected state on {G}%s{N}.\n" "${_name}"
    if ! LANG=C virsh metadata --config --domain "${_name}" --uri "${NSURI}protect" --remove &>/dev/null
    then
      _abort_script "Unable to set unprotected state on {G}%s{N}..." "${_name}"
    fi
  fi
}

_vm_hide() {
local _name="${1}" _desc
  if [[ -n "${_name}" ]]
  then
    if ! _desc=$(LANG=C virsh desc "${_name}" 2>/dev/null)
    then
      _abort_script "virtual machine {G}%s{N} not found" "${_name}"
    fi
    if [[ ! ${_desc} =~ rskvm ]]
    then
      _abort_script "virtual machine not supported by $ME"
    fi
    _verbose_printf "Setting hidden state on {G}%s{N}.\n" "${_name}"
    if ! LANG=C virsh metadata --config --domain "${_name}" --uri "${NSURI}hide" --key 'rskvm-hide' --set '<enable/>' &>/dev/null
    then
      _abort_script "Unable to set hidden state on {G}%s{N}..." "${_name}"
    fi
  fi
}

_vm_unhide() {
local _name="${1}" _desc
  if [[ -n "${_name}" ]]
  then
    if ! _desc=$(LANG=C virsh desc "${_name}" 2>/dev/null)
    then
      _abort_script "virtual machine {G}%s{N} not found" "${_name}"
    fi
    if [[ ! ${_desc} =~ rskvm ]]
    then
      _abort_script "virtual machine not supported by $ME"
    fi
    _verbose_printf "Setting unhidden state on {G}%s{N}.\n" "${_name}"
    if ! LANG=C virsh metadata --config --domain "${_name}" --uri "${NSURI}hide" --remove &>/dev/null
    then
      _abort_script "Unable to set unhidden state on {G}%s{N}..." "${_name}"
    fi
  fi
}

_vm_delete() {
local _name="${1}" _desc
  if [[ -n "${_name}" ]]
  then
    if ! _desc=$(LANG=C virsh desc "${_name}" 2>/dev/null)
    then
      _abort_script "virtual machine {G}%s{N} not found" "${_name}"
    fi
    if [[ ! ${_desc} =~ rskvm ]]
    then
      _abort_script "virtual machine not supported by $ME"
    fi
    if _is_vm_protected "${_name}"
    then
      _abort_script "virtual machine {G}%s{N} is protected" "${_name}"
    fi
    _verbose_printf "Shutting down VM {G}%s\n" "${_name}"
    if virsh shutdown "${_name}" --mode agent &>>~/.rskvm.log
    then
      sleep 1
    fi
    if virsh shutdown "${_name}" &>>~/.rskvm.log
    then
      sleep 1
    fi
    _verbose_printf "Removing VM {G}%s\n" "${_name}"
    virsh destroy --domain "${_name}" &>>~/.rskvm.log || true
    # Bug in Ubuntu 22.04? 
    # error: unsupported flags (0x2) in function virStorageBackendVolDeleteLocal
    # removed: --delete-storage-volume-snapshots
    virsh undefine --domain "${_name}" --remove-all-storage --managed-save --snapshots-metadata --checkpoints-metadata --nvram &>>~/.rskvm.log || true
    if [[ -f ${VM_STORAGE}/${_name}.vm ]]
    then
      _printf "orphan image: {R}%s.vm\n" "${_name}"
      rm -f "${VM_STORAGE}/${_name}.vm"
    fi
  fi
}

_vm_host_uri() {
local _host="${1}" _uri _addr _user _port
  _uri="qemu+ssh://"
  if _user=$(_config_get "/host/${_host}/user")
  then
    _uri="${_uri}${_user}@"
  fi
  _addr=$(_config_get_host "${_host}")
  _uri="${_uri}${_addr}"
  if _port=$(_config_get "/host/${_host}/port")
  then
    _uri="${_uri}:${_port}"
  fi
  _uri="${_uri}/system?command=rskvm-ssh-no-verify"
  echo -n "${_uri}"
}

_vm_run_console() {
local _name="${1}" _host="${2}" _uri _addr
  if _addr=$(_config_get_host "${_host}")
  then
    _uri="qemu:///system"
    _ssh --pass -t -enone "${_host}" virsh --connect="${_uri}" console --force --domain "${_name}"
  fi
}

_vm_run_viewer() {
local _name="${1}" _host="${2}" _uri _addr
  if [[ -n ${DISPLAY} ]]
  then
    if _addr=$(_config_get_host "${_host}")
    then
      # some hacks to be quiet
      ssh-keygen -R "${_addr}" &>/dev/null || true
      ssh-keyscan -H "${_addr}" 2>/dev/null >>~/.ssh/known_hosts || true
      _uri=$(_vm_host_uri "${_host}")
      (virt-viewer --connect="${_uri}" "${_name}"&)
    fi
  else
    _abort_script "missing env {R}DISPLAY\n"
  fi
}

_vm_start() {
local _vm="${1}"
  virsh start --domain "${_vm}" &>>~/.rskvm.log || true
}

# Process global options
_vm_manager() {
local _args=() _val

  if [[ -z $1 ]]
  then
    _usage
    exit 1
  fi

  _config_profile_set

  VERBOSE=0
  FORCE=0
  LIST=0
  LIST_Q=0
  LIST_IMAGES=0
  FLUSH_IMAGES=0
  UPDATE_IMAGES=0
  DEFAULT_IMAGE=""

  while [[ -n "${1}" ]]
  do
    _cmd="$1"
    case "${_cmd,,}" in
      --help|-h)
        _usage
        exit 1
        ;;
      --list|-l)
        LIST=1
        ;;
      --lq|-lq)
        LIST=1
        LIST_Q=1
        ;;
      --verbose|-v)
        VERBOSE=1
        ;;
      --remote)
        IS_REMOTE=1
        # quick fix for ssh ptty
        #stty -onlcr
        ;;
      --list-images|--list-templates|--templates|-t|list:images|list::images|list:templates|list::templates)
        LIST_IMAGES=1
        ;;
      --flush-images|--flush-templates|flush:images|flush::images|flush:templates|flush::templates)
        FLUSH_IMAGES=1
        ;;
      --update-images|--update-templates|update:images|update::images|update:templates|update::templates)
        UPDATE_IMAGES=1
        ;;
      default-image:*|default::image:*)
        if ! DEFAULT_IMAGE=$(_extract_param "${1}")
        then
          _abort_script "missing {G}default-image{N} name"
        fi
        ;;
      *)
        _args+=("${1}")
    esac
    shift
  done

  set -- "${_args[@]}"

  if [[ ${UPDATE_IMAGES} -eq 1 ]]
  then
    _vm_update_images
    exit
  fi
  if [[ ${FLUSH_IMAGES} -eq 1 ]]
  then
     _vm_flush_images "$@"
     exit
  fi

  if [[ -n ${DEFAULT_IMAGE} ]]
  then
    _vm_set_default_image "${DEFAULT_IMAGE}"
    exit
  fi
  if [[ ${LIST_IMAGES} -eq 1 ]]
  then
    _vm_list_images
    exit
  fi
  if [[ ${LIST} -eq 1 ]]
  then
     _list_vm "${LIST_Q}" "$@"
    exit
  fi
  _vm_manager_process "$@"
}

_vm_manager_process() {
local _rest=() _val _remote _action _hash _remote_hash

  if [[ -z $1 ]]
  then
    exit
  fi

  FORCE=0
  VM_CONSOLE=0
  VM_VIEWER=0
  VM_URI=0
  RSKVM_OPTS=":"

  _action=""
  _hash=""
  while [[ -n "${1}" ]]
  do
    _cmd="$1"
    case "${_cmd,,}" in
       cloud-config::*|cloud-config:*)
        if _val=$(_extract_param "${1}")
        then
          if _val=$(echo "${_val}" | base64 -d 2>/dev/null)
          then
            if [[ ${_val} =~ ^kvm-cnf-no-net! ]]
            then
              export _X_SOCHA_PROFILE="${_val}"
            else
              _abort_script "unknow data format for profile configuration"
            fi
          else
            _abort_script "garbage data as configuration profile passed"
          fi
        else
          _abort_script "{G}cloud-config{N} missing configuration"
        fi
        ;;
      profile::*|profile:*)
        if _val=$(_extract_param "${1}")
        then
          _runtime[profile]="${_val}"
        else
          _abort_script "missing {G}profile{N} name"
        fi
        ;;
      hash:*)
        if _val=$(_extract_param "${1}")
        then
          _hash="${_val}"
        fi
        ;;
      --force|-f)
        FORCE=1
        ;;
      --full)
        RSKVM_OPTS+="full:"
        ;;
      --link)
        RSKVM_OPTS="${RSKVM_OPTS//full:/}"
        ;;
      --nested)
        RSKVM_OPTS+="nested:"
        ;;
      --no-metadata|--no-config|--noconfig)
        RSKVM_OPTS+="noconfig:"
        ;;
      --stop)
        _action="stop"
        ;;
      --start)
        _action="start"
        ;;
      --create-wait|--wait)
        _action="create-wait"
        ;;
      --create)
        _action="create"
        ;;
      --query)
        _action="query"
        ;;
      --delete|--destroy)
        _action="delete"
        ;;
      --console|--con|--tty)
        _action="console"
        ;;
      --view|--viewer)
        _action="viewer"
        ;;
      --protect|--guard)
        _action="protect"
        ;;
      --unprotect|--unguard)
        _action="unprotect"
        ;;
      --hide)
        _action="hide"
        ;;
      --unhide)
        _action="unhide"
        ;;
      --exists|--exist)
        _action="exists"
        ;;
      --commit|--rebase)
        _action="commit"
         ;;
      *)
        _rest+=("${@}")
        break
    esac
    shift
  done
  set -- "${_rest[@]}"

  if [[ -z "${1}" ]]
  then
    return 0
  fi
  _vm_parse_spec "${_action}" "$@"
  if [[ ${RSKVM_DO} == "console" ]]
  then
      _vm_run_console "${RSKVM_NAME}" "${RSKVM_HOST}"
  elif [[ ${RSKVM_DO} == "viewer" ]]
  then
      _vm_run_viewer "${RSKVM_NAME}" "${RSKVM_HOST}"
  elif [[ ${RSKVM_HOST} == "localhost" ]]
  then
    _config_default_bridge
    case "${RSKVM_DO}" in
      start)
        _vm_start "${RSKVM_NAME}"
        ;;
      stop)
        if ! virsh shutdown --mode agent --domain "${RSKVM_NAME}" &>>~/.rskvm.log
        then
          virsh shutdown --domain "${RSKVM_NAME}" &>>~/.rskvm.log || true
        fi
        ;;
      create-wait|create)
        vm_create ${RSKVM_NAME} ${RSKVM_TEMPLATE} ${RSKVM_RAM} ${RSKVM_CPU} "${RSKVM_OPTS}" "${_hash}"
        if [[ ${RSKVM_DO} == "create-wait" ]]
        then
          _vm_wait_for_me "${RSKVM_NAME}" "$(_who_am_i)" "${RSKVM_TEMPLATE}"
        fi
        ;;
      query)
        _val=$(_vm_get_ip4_addr "${RSKVM_NAME}")
        if [[ -n ${_val} ]]
        then
          printf "%s\n" "${_val}"
        fi
        ;;
      exists)
        if _is_vm_exists "${RSKVM_NAME}"
        then
          echo -n "1"
        else
          echo -n "0"
        fi
        exit 0
        ;;
      delete)
        _vm_delete "${RSKVM_NAME}"
        ;;
      commit)
        _vm_commit_backing "${RSKVM_NAME}"
        ;;
      protect|guard)
        _vm_protect "${RSKVM_NAME}"
        exit 0
        ;;
      unprotect|unguard)
        _vm_unprotect "${RSKVM_NAME}"
        exit 0
        ;;
      hide)
        _vm_hide "${RSKVM_NAME}"
        exit 0
        ;;
      unhide)
        _vm_unhide "${RSKVM_NAME}"
        exit 0
        ;;
      console)
        ;;
      viewer)
        ;;
      *)
        _abort_script "unsupported action: {G}%s" "${RSKVM_DO}"
    esac
  else
    _remote="--remote"
    if [[ ${VERBOSE} -eq 1 ]]
    then
      _remote="${_remote} --verbose"
    fi
    case "${RSKVM_DO}" in
      create|create-wait)
        _val=$(_config_vm_profile_get)
        if [[ -n ${_val} ]]
        then
          _val=$(echo -n "${_val}" | base64 -w 0)
          _remote="${_remote} cloud-config:${_val}"
        fi
      ;;
    esac
    if [[ ${RSKVM_OPTS} =~ :full: ]]
    then
      _remote="${_remote} --full"
    fi
    if [[ ${RSKVM_OPTS} =~ :noconfig: ]]
    then
      _remote="${_remote} --no-config"
    fi
    if [[ ${RSKVM_OPTS} =~ :nested: ]]
    then
      _remote="${_remote} --nested"
    fi
    if _remote_hash=$(_config_get "image/master/${RSKVM_TEMPLATE}/hash")
    then
      _remote="${_remote} hash:${_remote_hash}"
    fi
    if ! _ssh "${RSKVM_HOST}" ${_remote}  --${RSKVM_DO} ${RSKVM_NAME}/${RSKVM_TEMPLATE}:${RSKVM_RAM}:${RSKVM_CPU}
    then
      _abort_script "remote ssh invocation failed!"
    fi
  fi
  shift
  if [[ -n ${1} ]]
  then
    _vm_manager_process "$@"
  fi
}

_check_host_is_fresh() {
  if command -v virsh &>/dev/null
  then
    return 1
  fi
  if command -v virt-install &>/dev/null
  then
    return 1
  fi
  if command -v qemu-img &>/dev/null
  then
    return 1
  fi
  return 0
}

_is_correct_subnet() {
local _subnet="$1" _net_addr _net _netmask _ip_string _cidr_string
  _ip_string=$(_ip_from_cidr "${_subnet}")
  _cidr_string=$(_cidr_from_cidr "${_subnet}")
  if [[ ${_cidr_string} -gt 24 ]]
  then
    return 1
  fi
  if [[ ${_cidr_string} -lt 16 ]]
  then
    return 1
  fi
  _net=$(_ip2long "${_ip_string}")
  _netmask=$(_cidr2long "${_cidr_string}")
  _net_addr=$(( _net & _netmask ))
  if [[ ${_net_addr} -eq ${_net} ]]
  then
    return 0
  fi
  return 1
}

_netmask_from_subnet() {
local _subnet="$1" _netmask _cidr_string
  _cidr_string=$(_cidr_from_cidr "${_subnet}")
  _netmask=$(_cidr2long "${_cidr_string}")
  echo -n $(_long2ip "${_netmask}")
}

_first_ip_from_subnet() {
local _subnet="$1" _net_addr _ip_string
  _ip_string=$(_ip_from_cidr "${_subnet}")
  _net_addr=$(_ip2long "${_ip_string}")
  echo -n $(_long2ip $((++_net_addr)))
}

_start_ip_from_subnet() {
local _subnet="$1" _net_addr _ip_string  _prefix
  _ip_string=$(_ip_from_cidr "${_subnet}")
  _prefix=$(_cidr_from_cidr "${_subnet}")
  _net_addr=$(_ip2long "${_ip_string}")
  if [[ ${_prefix} -ge 24 ]]
  then
    _net_addr=$(( _net_addr + 64 ))
  else
    _net_addr=$(( _net_addr + 256 ))
  fi
  echo -n $(_long2ip ${_net_addr})
}

_end_ip_from_subnet() {
local _subnet="$1" _net_addr _net _netmask _ip_string _cidr_string
  _ip_string=$(_ip_from_cidr "${_subnet}")
  _cidr_string=$(_cidr_from_cidr "${_subnet}")
  _net=$(_ip2long "${_ip_string}")
  _netmask=$(_cidr2long "${_cidr_string}")
  _netmask=$(( ~_netmask ))
  _net_addr=$(( (_net | _netmask) - 1 ))
  echo -n $(_long2ip ${_net_addr})
}

_is_netmask_subnet_valid() {
local _subnet="$1" _netmask="$2" _net _cidr
  if _is_ip "${_netmask}"
  then
    _cidr=$(_cidr_from_cidr "${_subnet}")
    _net=$(_cidr2long "${_cidr}")
    _netmask=$(_ip2long "${_netmask}")
    if [[ ${_net} -eq ${_netmask} ]]
    then
      return 0
    fi
  fi
  return 1
}

_is_ip_subnet_valid() {
local _subnet="$1" _first_ip="$2" _start_ip="$3" _end_ip="$4" _net _cidr _netmask _ip _last_ip
  for _ip in "${_first_ip}" "${_start_ip}" "${_end_ip}"
  do
    if ! _is_ip "${_ip}"
    then
      return 1
    fi
  done
  _net=$(_ip_from_cidr "${_subnet}")
  _net=$(_ip2long "${_net}")
  _cidr=$(_cidr_from_cidr "${_subnet}")
  _netmask=$(_cidr2long "${_cidr}")
  _first_ip=$(_ip2long "${_first_ip}")
  _start_ip=$(_ip2long "${_start_ip}")
  _end_ip=$(_ip2long "${_end_ip}")
  _last_ip=$(( _net | (~_netmask & 0xffffffff)))
  if [[ $(( _net & _netmask )) -eq $(( _first_ip & _netmask )) ]]
  then
    if [[ $(( _net & _netmask )) -eq $(( _start_ip & _netmask )) ]]
    then
      if [[ $(( _net & _netmask )) -eq $(( _end_ip & _netmask )) ]]
      then
        if [[ ${_start_ip} -gt ${_first_ip} ]]
        then
          if [[ ${_start_ip} -lt ${_end_ip} ]]
          then
            if [[ ${_end_ip} -lt ${_last_ip} ]] && [[ $(( _end_ip - _start_ip )) -ge 128  ]]
            then
              return 0
            fi
          fi
        fi
      fi
    fi
  fi
  return 1
}

_setup_host() {
local _user _force=0 _remote=0 _arg _subnet _net _netmask _first_ip _start_ip _end_ip _ssh_port="22" _verbose=0 _pkgs
  for _arg in $@
  do
    case "${_arg,,}" in
      subnet:*)
        _subnet=$(_extract_param "${_arg}")
        ;;
      net:*)
        _net=$(_extract_param "${_arg}")
        IFS="/" read _first_ip _start_ip _end_ip <<< $"${_net}"
        ;;
      ssh-port:*)
        _ssh_port=$(_extract_param "${_arg}")
        ;;
      --force)
        _force=1
        ;;
      --remote)
        _remote=1
        ;;
      --verbose)
        _verbose=1
        ;;
    esac
  done
  if [[ -z ${_subnet} ]]
  then
    _abort_script "{G}subnet{R} parameter is required"
  fi

  if [[ -z ${_ssh_port} ]]
  then
    _ssh_port="22"
  fi

  if [[ ${_subnet} != "local" ]]
  then
    if ! _is_cidr "${_subnet}"
    then
      _abort_script "{R}incorrect {G}subnet{R} format"
    fi

    if ! _is_correct_subnet "${_subnet}"
    then
      _abort_script "{R}incorrect {G}subnet{R} address given"
    fi
    _netmask=$(_netmask_from_subnet "${_subnet}")
    if [[ -z ${_first_ip} ]] || [[ -z ${_start_ip} ]] || [[ -z ${_end_ip} ]]
    then
      _first_ip=$(_first_ip_from_subnet "${_subnet}")
      _start_ip=$(_start_ip_from_subnet "${_subnet}")
      _end_ip=$(_end_ip_from_subnet "${_subnet}")
    fi

    if ! _is_ip_subnet_valid "${_subnet}" "${_first_ip}" "${_start_ip}" "${_end_ip}"
    then
      _abort_script "{R}invalid network specification for {G}subnet"
    fi
  fi

  if [[ -n ${FOR_USER} ]]
  then
    _user="${FOR_USER}"
  elif [[ -n ${SUDO_USER} ]]
  then
    _user="${SUDO_USER}"
  else
    _user="${USER}"
  fi
  if [[ -f /etc/os-release ]]
  then
    source "/etc/os-release"
    if [[ "${ID}" == "ubuntu" ]]
    then
      case "${VERSION_ID}" in
        20.04|22.04)
          ;;
        *)
        _abort_script "unsupported Ubuntu version %s" "${VERSION_ID}"
      esac
    elif [[ "${ID}" == "debian" ]]
    then
      case "${VERSION_ID}" in
        11)
          ;;
        *)
        _abort_script "unsupported Debian version %s" "${VERSION_ID}"
      esac
    else
      _abort_script "sorry, distribution {G}%s" "${ID}"
    fi
    if ! _check_host_is_fresh
    then
      if [[ ${_force} -eq 0 ]]
      then
        _abort_script "the host is already configured (add {G}--force{N})"
      fi
    fi
    if [[ $(id -u) -ne 0 ]]
    then
      _abort_script "run me as root: {G}sudo $0 setup::host subnet:${_subnet} {N}or {Y}sudo !!"
    fi
    _printf "Installation of required packages ... {+}{G}please wait {N}..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update &>>~/.rskvm.log
    apt-get dist-upgrade -y &>>~/.rskvm.log
    _pkgs=()
    _pkgs+=( "qemu-kvm" )
    _pkgs+=( "virtinst" )
    _pkgs+=( "libvirt-daemon" )
    _pkgs+=( "libvirt-clients" )
    _pkgs+=( "qemu-utils" )
    _pkgs+=( "bridge-utils" )
    _pkgs+=( "libvirt-daemon-driver-qemu" )
    _pkgs+=( "libvirt-daemon-system" )
    _pkgs+=( "qemu-system-x86" )
    _pkgs+=( "cpu-checker" )
    _pkgs+=( "gpg" )
    _pkgs+=( "gpg-agent" )
    _pkgs+=( "curl" )
    _pkgs+=( "jq" )
    if [[ ${_subnet} != "local" ]]
    then
      _pkgs+=( "dnsmasq-base" )
      _pkgs+=( "netfilter-persistent" )
      _pkgs+=( "iptables-persistent" )
    fi
    apt-get install -y --no-install-recommends ${_pkgs[@]} &>>~/.rskvm.log
    _printf "\rInstallation of required packages ... {G} DONE {N}...       \n"

    if [[ ${_subnet} != "local" ]]
    then
      _printf "Configuration of iptables\n"
      if [[ -f /etc/iptables/rules.v4 ]] && [[ ! -f /etc/iptables/rules.v4.save.rskvm ]]
      then
        cp "/etc/iptables/rules.v4" "/etc/iptables/rules.v4.save.rskvm"
      fi
      echo -n "$PAYLOAD_IPTABLES_RULES" | base64 -d | SUBNET="${_subnet}" HOST_SSH_PORT="${_ssh_port}" envsubst '$SUBNET $HOST_SSH_PORT' >/etc/iptables/rules.v4
      systemctl restart netfilter-persistent
      #_printf "Configuration of ip forwarding...\n"
      #echo -n "$PAYLOAD_SYSCTL_FORWARD" | base64 -d >/etc/sysctl.d/ip_forward.conf
      #sysctl -p /etc/sysctl.d/ip_forward.conf >/dev/null
      echo -n "$PAYLOAD_VIRT_NET_DEFAULT" | base64 -d | NET_DNS_SERVER="10.53.53.53" NET_DOMAIN="vm" IP_GW="${_first_ip}" IP_NETMASK="${_netmask}" IP_START="${_start_ip}" IP_END="${_end_ip}" envsubst '$IP_START $IP_END $IP_NETMASK $IP_GW $NET_DOMAIN $NET_DNS_SERVER' >/tmp/default.xml
      if virsh net-info default &>/dev/null
      then
        virsh net-destroy default &>/dev/null || true
        virsh net-undefine default &>/dev/null || true
      fi
      virsh net-define /tmp/default.xml
      virsh net-start default
      virsh net-autostart default
      rm /tmp/default.xml
    fi
    if [[ ${_remote} -eq 0 ]]
    then
      _printf "\n{G}READY\n\n"
      _printf "run:\n\n"
      _printf "  {Y}$ME -c me:<name>\n"
      _printf "  {Y}$ME -m user:${_user}@? user:root@? ssh:root@~/.ssh/authorized_keys ssh:${_user}@~/.ssh/authorized_keys group:sudo@${_user}\n"
      _printf "  {Y}exec newgrp libvirt\n"
      _printf "  {Y}exec newgrp $_user\n"
      _printf "\nextra:\n\n"
      _printf "  {Y}echo 'alias cssh=\"ssh -o LogLevel=QUIET -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null\"' >>~/.bash_aliases\n"
      _printf "\n"
    fi
  else
    _abort_script "missing /etc/os-relase"
 fi
}

_ssh_to_vm() {
local _host _name _remote=0 _ip _opts  _user=""
  if [[ ${1} =~ @ ]]
  then
    _host="${1##*@}"
    _name="${1%%@*}"
  else
    _host=""
    _name="${1}"
  fi
  shift
  if [[ ${1} == "--remote" ]]
  then
    _remote=1
    shift
  fi
  if [[ $_remote -eq 1 ]]
  then
    if [[ ${_name} =~ / ]]
    then
      _user="${_name%%/*}"
      _name="${_name##*/}"
    fi
    _ip=$(_vm_get_ip4_addr "${_name}")
    if [[ -n ${_ip} ]]
    then
      _opts="-t -o LogLevel=QUIET -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
      if [[ -n ${_user} ]]
      then
        ssh ${_opts} ${_user}@${_ip} "$@"
      else
        ssh ${_opts} ${_ip} "$@"
      fi
    fi
  else
    if [[ ! ${_name} =~ / ]]
    then
      # append calling user
      _name="${USER}/${_name}"
    fi
    _ssh -t "${_host}" ssh:${_name} --remote "$@"
  fi
  exit
}

_setup_remote_host_test() {
local _host="${1}" _out
  shift
  if _out=$(_ssh --pass -t "${_host}" $@)
  then
    echo -n "${_out}"
    return 0
  fi
  return 1
}

_is_ip() {
  if [[ ${1} =~ ^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$ ]]
  then
    return 0
  fi
  return 1
}

_ip_from_cidr() {
  if _is_cidr ${1}
  then
    echo "${1%%/*}"
  fi
}

_cidr_from_cidr() {
  if _is_cidr $1
  then
    echo "${1##*/}"
  fi
}

_ip2long() {
local ip="${1}" o1 o2 o3 o4
  if _is_ip "${1}"
  then
    IFS="." read o1 o2 o3 o4 <<< "$ip"
    echo -n $(( ($o1 << 24) + ($o2 << 16) + ($o3 << 8) + $o4))
  fi
}

_long2ip() {
local _long="$1"
  if [[ ${_long} =~ ^-?[0-9]+$ ]]
  then
    _long=$(( _long & 0xffffffff ))
    echo -n "$(((${_long} >> 24)&255)).$(((${_long} >> 16)&255)).$(((${_long} >> 8)&255)).$((${_long}&255))"
  fi
}

_cidr2long() {
  if [[ -n $1 && $1 =~ ^[0-9]+$ ]] && [[ $1 -ge 0 && $1 -le 32 ]]
  then
    echo -n $((~((1<<(32-$1))-1)&0xffffffff))
  fi
}

_is_cidr() {
  if [[ $# -eq 1 ]]
  then
    if [[ ${1} =~ ^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])/(3[012]|[12]?[0-9])$ ]]
    then
      return 0
    fi
  fi
  return 1
}

# zt installer sucks :)
_install_zerotier_one() {
  curl --connect-timeout "${CURL_TIMEOUT}" -s https://install.zerotier.com | sudo bash &>/dev/null
  if [[ -n ${1} ]]
  then
    # make sure w starting with new identity?
    systemctl start zerotier-one
    _printf "Joining ZT network: {Y}%s\n" "${1}"
    zerotier-cli join "${1}"
  fi
}

_zt_get_address() {
  if [[ -x /usr/sbin/zerotier-cli ]]
  then
    /usr/sbin/zerotier-cli info | awk '{print $3}'
  else
    _abort_script "ZeroTier One is not installed..."
  fi
}

# a lot of assumptions - hey yeahhhh...
_setup_remote_host() {
local _host="${1}" _name _val _asroot=0 _subnet _overlay _zt_net _zt_net_address _zt_node _first_ip _start_ip _end_ip _netmask _prefix _ip _net _ssh_port _zt_ip=""
  shift
  while [[ -n ${1} ]]
  do
    case "${1,,}" in
      overlay-network:*|overlay:*)
        if _overlay=$(_extract_param "${1}")
        then
          if _val=$(_config_get "/overlay/${_overlay}/provider")
          then
            :
          else
            _printf "{Y}WARNING:{N} only ZT supported at this time - option ignored...\n"
          fi
        else
          _abort_script "missing {G}overlay{N} network provider"
        fi
        shift
        ;;
      zt-network:*|zt-net:*|zt:*)
        if ! _zt_net=$(_extract_param "${1}")
        then
          _abort_script "missing {G}zt-net{N} network name/address"
        fi
        if ! _zt_net_address=$(_config_get "/overlay/zt/${_zt_net}/network")
        then
          _abort_script "unknown ZT network selected"
        fi
        _config_put "/host/${_host}/overlay/zt/network" "${_zt_net}"
        _config_put "/overlay/zt/current" "${_zt_net}"
        shift
        ;;
      zt-ip:*)
        if _val=$(_extract_param "${1}")
        then
          if _is_ip "${_val}"
          then
            _zt_ip="${_val}"
          fi
        fi
        shift
        ;;
      subnet:*)
        if ! _subnet=$(_extract_param "${1}")
        then
          _abort_script "missing {G}subnet{N} prefix"
        fi
        if ! _is_cidr "${_subnet}"
        then
          _abort_script "this is not network prefix: {G}%s\n" "${_subnet}"
        fi
        shift
        ;;
        *)
          _printf "{Y}WARNING:{N} skipping unknown option {G}%s\n" "${1}"
          shift
    esac
  done
  if [[ -z ${_subnet} ]]
  then
    _abort_script "{G}subnet{N} prefix not provided"
  fi
  if [[ -z ${_zt_net_address} ]]
  then
      if _zt_net=$(_config_get "/overlay/zt/current")
      then
        _printf "{Y}WARNING: {N} autoselect ZT netowork: {G}%s{N}\n" "${_zt_net}"
        if ! _zt_net_address=$(_config_get "/overlay/zt/${_zt_net}/network")
        then
          _abort_script "unknown ZT network selected"
        fi
      else
          _abort_script "no ZT network definied"
      fi
  fi
  _ip=$(_ip_from_cidr $_subnet)
  _prefix=$(_cidr_from_cidr ${_subnet})
  _netmask=$(_cidr2long ${_prefix})
  _net=$(_ip2long ${_ip})
  # check if we are on subnet boundary
  if [[ $(( ${_net} & ${_netmask} )) -ne ${_net} ]]
  then
    _abort_script "incorrect subnet prefix!"
  fi
  if [[ ${_prefix} -gt 24 ]]
  then
    _abort_script "subnet to small!"
  fi
  # Last IP in the pool
  _end_ip=$(( (~${_netmask} & 0xffffffff) - 1 ))
  _end_ip=$(_long2ip $(( ${_net} | ${_end_ip})))
  _first_ip=$(_long2ip $(( ${_net} + 1)))
  _start_ip=$(_long2ip $(( ${_net} + 2)))
  _netmask=$(_long2ip ${_netmask})

  if ! _val=$(_config_get "/host/${_host}/address")
  then
    _abort_script "host {G}%s{N} not definied" "${_host}"
  fi
  _printf "Checking conectivity to host {G}%s\n" "${_host}"
  if ! _val=$(_setup_remote_host_test "${_host}" true)
  then
    _abort_script "connection to {G}${_host}{N} failed"
  fi
  _printf "Checking root access\n"
  if ! _val=$(echo 'echo -n $(id -u)' | _setup_remote_host_test "${_host}" bash -s )
  then
    _abort_script "connection to {G}${_host}{N} failed"
  fi
  if ! [[ ${_val} =~ ^[0-9]+$ ]]
  then
    _abort_script "sorry unexpected error: X%sX" "${_val}"
  fi
  if [[ ${_val} -eq 0 ]]
  then
    _asroot=1
    _printf "Connected as {Y}root{N} - user {G}rskvm{N} will be {*}created{N} at later stage\n"
    _config_put "/host/${_host}/as-root" "direct"
  else
    # some sudo support?
    _abort_script "unable to continue - not {G}root{N} user configured"
  fi
  _printf "Transfering {Y}%s{N} to host {G}%s\n" "$0" "${_host}"
  if ! cat $0 | _ssh --pass -enone "${_host}" "dd if=/dev/stdin of=/usr/bin/$ME status=none && chmod +x /usr/bin/$ME && rskvm transfer:was-ok"
  then
    _abort_script "unable to transfer {Y}${ME}{N} to remote host..."
  fi
  _printf "Starting configuration process...\n"
  # change this for parameter
  _ssh_port="22"
  if _val=$(_config_get "/host/${_host}/port")
  then
    _ssh_port="${_val}"
  fi
  if ! _ssh --pass "${_host}" FOR_USER=rskvm rskvm setup::host --remote --force subnet:${_subnet} ssh-port:${_ssh_port}
  then
    _abort_script "configuration failed..."
  fi
  if [[ -n ${_zt_net_address} ]]
  then
    _printf "Installing Zerotier-One\n"
    if ! _ssh "${_host}" install-zt:${_zt_net_address}
    then
      _abort_script "zt installation failed"
    fi
    if ! _zt_node=$(_ssh "${_host}" zt-address:get)
    then
      _abort_script "unable to retrevie ZT node address..."
    fi
    # for ZT API call (later)
    _printf "ZT node address: {G}%s\n" "${_zt_node}"
    _config_put "/host/${_host}/overlay/zt/node" "${_zt_node}"
    _printf "Auto register in ZeroTier One network: "
    _done=0
    _cnt=1
    while [[ $_done -eq 0 ]]
    do
      if [[ $_cnt -gt 60 ]]
      then
        break
      fi
      if _val=$(_zt_authorize_node "${_zt_node}" "${_zt_ip}")
      then
        if [[ -n ${_val} ]]
        then
          break
        fi
      fi
      echo -n "."
      sleep 1
      ((_cnt++)) || true
    done
    if [[ -n ${_val} ]]
    then
      _printf " {G}OK{N}\n"
      _printf "NodeIP: {G}%s\n" "${_val}"
      if _is_ip "${_val}"
      then
        _config_put "/host/${_host}/overlay/zt/address" "${_val}"
        _printf "Setup route to {G}%s {N}via {Y}%s\n" "${_subnet}" "${_val}"
        _zt_set_route "${_subnet}" "${_val}"
      else
        _printf "{+}{Y}WARNING{N}: ZT - wrong IP format: {G}%s\n" "${_val}"
      fi
      if _zt_rename_node "${_zt_node}" "${_host}"
      then
        _printf "Change ZT node name to {G}%s\n" "${_host}"
      fi
      _config_put "/host/${_host}/subnet" "${_subnet}"
    else
      _printf " {R}FAIL{N}\n"
    fi
    #_printf "At the moment:\n"
    #_printf " Confirm node join in ZT web UI and add route to: ${_subnet}\n"
  fi
  if [[ ${_asroot} -eq 1 ]]
  then
    if _ssh -A "${_host}" host-config-user:rskvm
    then
      _config_put "/host/${_host}/user" "rskvm"
      if ! _ssh "${_host}" -c me:${_host}
      then
        _abort_script "unable to setup own name"
      fi
    else
      _abort_script "unable to setup user {G}%s" "rskvm"
    fi
  fi
}

# only ssh-agent support
_host_config_user() {
local _user="${1}"
  if ! getent passwd "${_user}" &>/dev/null
  then
    useradd -s /bin/bash -m "${_user}"
  fi
  cd $(eval echo ~${_user})
  # custom ssh config (private use)
  if [[ -d /etc/ssh-pool ]]
  then
    ssh-add -L >"/etc/ssh-pool/${_user}"
  else
    if [[ ! -d .ssh ]]
    then
      mkdir -p -m 700 .ssh
    fi
    ssh-add -L >.ssh/authorized_keys
    chown -R ${_user}:${_user} .ssh
  fi
  gpasswd -a ${_user} libvirt
  # make sure home folder is accesible for libvirt (for Ubuntu 22.04 is not by default)
  chmod o+x .
}

_zt_api_get() {
local _ztnet _api _network _resp _val _url="$1" _extract="$2" _mode="${3}"
  if ! command -v jq &>/dev/null
  then
    return 1
  fi
  if ! _ztnet=$(_config_get "/overlay/zt/current")
  then
    _abort_script "ZT overlay network not selected (use overlay:zt:name:<NAME> first)"
  fi
  if ! _api=$(_config_get "/overlay/zt/${_ztnet}/api")
  then
    return 1
  fi
  if ! _network=$(_config_get "/overlay/zt/${_ztnet}/network")
  then
    return 1
  fi
  if ! _resp=$(curl --connect-timeout "${CURL_TIMEOUT}" -sf -X GET -H "Content-Type: application/json" -H "Authorization: bearer ${_api}"  "${ZT_API}/network/${_network}${_url}")
  then
    return 1
  fi
  if ! _val=$(jq ${_mode} "${_extract}" <<< "${_resp}")
  then
    return 1
  fi
  echo -n "${_val}"
}

_zt_api_set() {
local _api _network _ztnet _resp _val
  if ! command -v jq &>/dev/null
  then
    return 1
  fi
  if ! _ztnet=$(_config_get "/overlay/zt/current")
  then
    _abort_script "ZT overlay network not selected (use overlay:zt:name:<NAME> first)"
  fi
  if ! _api=$(_config_get "/overlay/zt/${_ztnet}/api")
  then
    return 1
  fi
  if ! _network=$(_config_get "/overlay/zt/${_ztnet}/network")
  then
    return 1
  fi
  if [[ $# -eq 2 ]]
  then
    if curl --connect-timeout "${CURL_TIMEOUT}" -o /dev/null -sf -X POST -H "Content-Type: application/json" -H "Authorization: bearer ${_api}" --data "${2}" "${ZT_API}/network/${_network}${1}"
    then
      return 0
    fi
    return 1
  else
    if ! _resp=$(curl --connect-timeout "${CURL_TIMEOUT}" -sf -X POST -H "Content-Type: application/json" -H "Authorization: bearer ${_api}" --data "${3}" "${ZT_API}/network/${_network}${1}")
    then
      return 1
    fi
    if ! _val=$(jq $4 "${2}" <<< "${_resp}")
    then
      return 1
    fi
    echo -n "${_val}"
  fi
}

_zt_api_delete() {
local _api _network _ztnet _resp _val
  if ! command -v jq &>/dev/null
  then
    return 1
  fi
  if ! _ztnet=$(_config_get "/overlay/zt/current")
  then
    _abort_script "ZT overlay network not selected (use overlay:zt:name:<NAME> first)"
  fi
  if ! _api=$(_config_get "/overlay/zt/${_ztnet}/api")
  then
    return 1
  fi
  if ! _network=$(_config_get "/overlay/zt/${_ztnet}/network")
  then
    return 1
  fi
  if [[ -n ${1} ]]
  then
    if curl --connect-timeout "${CURL_TIMEOUT}" -sf -o /dev/null -X DELETE -H "Content-Type: application/json" -H "Authorization: bearer ${_api}" "${ZT_API}/network/${_network}${1}"
    then
      return 0
    fi
  fi
  return 1
}


# $1 subnet $2 via
_zt_set_route() {
local _routes
  if _routes=$(_zt_api_get "" ".config.routes" -c)
  then
    #_printf "Current routes: %s\n" "${_routes}"
    _routes=$(jq -c '. |= . + [{"target":"'${1}'","via":"'${2}'"}]' <<< "${_routes}")
    #_printf "New: %s\n" "${_routes}"
    _zt_api_set "" '{"config": { "routes": '${_routes}'} }'
  fi
}

# $1 subnet $2 via
_zt_del_route() {
local _routes _diff
  if _routes=$(_zt_api_get "" ".config.routes" -c)
  then
    #_printf "Current routes: %s\n" "${_routes}"
    _diff=$(jq -c 'del(.[] | select(.target == "'${1}'"))' <<< "${_routes}")
    if [[ "${_diff}" != "${_routes}" ]]
    then
      _verbose_printf "ZT/Route update:\n{G}%s{Y}%s\n" "${_routes}" "${_diff}"
      _zt_api_set "" '{"config": { "routes": '${_diff}'} }'
    fi
  fi
}

_zt_authorize_node() {
local _result _ip="${2}"
  if [[ -n ${_ip} ]]
  then
    if _result=$(_zt_api_set "/member/${1}" ".config.ipAssignments[]" "{\"config\":{\"authorized\": true,\"ipAssignments\": [ \"${_ip}\"]}}" -r)
    then
      echo -n "${_result}"
      return 0
    fi
  else
    if _result=$(_zt_api_set "/member/${1}" ".config.ipAssignments[]" '{"config":{"authorized": true}}' -r)
    then
      echo -n "${_result}"
      return 0
    fi
  fi
  return 1
}

_zt_unauthorize_node() {
local _result
  if _result=$(_zt_api_set "/member/${1}" "." '{ "config": {"authorized": false,"ipAssignments": []}}' -c)
  then
    if _result=$(_zt_api_delete "/member/${1}")
    then
      return 0
    fi
  fi
  return 1
}

_zt_rename_node() {
  if _zt_api_set "/member/${1}" "{\"name\":\"${2}\", \"description\": \"Managed by RSKVM\"}"
  then
    return 0
  fi
  return 1
}

_zt_verify_api() {
local _api _network _resp _val _ztnet
  if ! command -v jq &>/dev/null
  then
    _abort_script "missing required command {G}jq{N}"
  fi
  if _ztnet=$(_config_get "/overlay/zt/current")
  then
    if ! _api=$(_config_get "/overlay/zt/${_ztnet}/api")
    then
      _abort_script "missing ZT {G}API{N} key for network ${_ztnet}"
    fi
    if ! _network=$(_config_get "/overlay/zt/${_ztnet}/network")
    then
      _abort_script "missing ZT {G}network{N} ID for network ${_ztnet}"
    fi
    if ! _resp=$(curl --connect-timeout "${CURL_TIMEOUT}" -sf -X GET -H "Content-Type: application/json" -H "Authorization: bearer ${_api}"  "${ZT_API}/network/${_network}")
    then
      _abort_script "connection to ZT's API service failed"
    fi
    if _val=$(jq -r .id <<< ${_resp} 2>/dev/null)
    then
      if [[ ${_val} == ${_network} ]]
      then
        _printf "ZT API (${_ztnet}/${_network}): {G}OK\n"
      else
        _abort_script "ZT missmatch networks"
      fi
    else
      _abort_script "unable to verify API access"
    fi
  else
    _abort_script "ZT overlay network not selected (use overlay:zt:name:<NAME> first)"
  fi
}

_is_root_required() {
local _me=$(uname -s)
  _me="${_me,,}"
  case "${_me}" in
    cygwin*)
      return 1
      ;;
  esac
  return 0
}

_self_update() {
  if [[ $(id -u) -ne 0 ]]
  then
    if _is_root_required
    then
      if [[ -t 0 ]]
      then
        exec sudo $0 me:update
      else
        _abort_script "run me as root: {G}sudo $0 me:update"
      fi
    fi
  fi
  if curl --connect-timeout "${CURL_TIMEOUT}" -sL -o /usr/bin/rskvm https://github.com/rjsocha/rskvm/releases/latest/download/rskvm
  then
    chmod +x /usr/bin/rskvm
    exec /usr/bin/rskvm me:install
  else
    _abort_script "Unable to {G}self-update{R}!"
  fi
}

_install() {
  if [[ -z $SCRIPT_DIR ]]
  then
    _abort_script "don't run me in inline mode..."
  fi
  if [[ $(id -u) -ne 0 ]]
  then
    if _is_root_required
    then
      if [[ -t 0 ]]
      then
        exec sudo bash $0 me:install
      else
        _abort_script "run me as root: {G}sudo $0 me:install"
      fi
    fi
  fi
  if [[ "$0" != "/usr/bin/rskvm" ]]
  then
    cp $0 /usr/bin/rskvm
    chmod +x /usr/bin/rskvm
  fi
  echo -n "${PAYLOAD_RSKVM_SSH_NO_VERIFY}" | base64 -d | dd of=/usr/bin/rskvm-ssh-no-verify status=none
  chmod +x /usr/bin/rskvm-ssh-no-verify
  _printf "{G}INSTALL OK: {Y}$(rskvm me:version)\n"
  exit 0
}

_check_runtime() {
  if ! command -v curl &>/dev/null
  then
    _abort_script "{G}curl{R} is required..."
  fi
  if ! command -v ssh &>/dev/null
  then
    _abort_script "{G}ssh{R} is required..."
  fi
  if ! command -v ssh &>/dev/null
  then
    _abort_script "{G}ssh{R} is required..."
  fi
  if ! command -v jq &>/dev/null
  then
    _abort_script "{G}jq{R} is required..."
  fi
}

_show_backing_templates() {
local _host="${1}" _image _backing
  for _image in $(find "${VM_STORAGE}" -type f -printf "%P\n")
  do
    if _backing=$(LANG=C qemu-img info --force-share --output=json "${VM_STORAGE}/${_image}" | jq -er '."full-backing-filename"')
    then
      echo  "${_image} ${_backing#${TEMPLATES}/}"
    fi
  done
}

_show_unused_templates() {
local _template _image
  IFS=$'\t\n'
  declare -A used=()
  declare -a remove=()
  for _image in $(find "${VM_STORAGE}" -type f -printf "%P\n")
  do
    if _backing=$(LANG=C qemu-img info --force-share --output=json "${VM_STORAGE}/${_image}" | jq -er '."full-backing-filename"')
    then
      _backing="$(basename "${_backing}")"
      used[${_backing}]="used"
    fi
  done
  for _image in $(find "${TEMPLATES}" -maxdepth 1 -mindepth 1 -type d -printf "%P\n")
  do
    for _template in $(find "${TEMPLATES}/${_image}" -maxdepth 1 -mindepth 1 -type f -printf "%P\n")
    do
      if [[ -n ${used[${_template}]+used} ]]
      then
        continue
      fi
      remove+=( "${TEMPLATES}/${_image}/${_template}" )
      [[ -n ${1:-} ]] || printf -- "%s/%s/%s\n" "${TEMPLATES}" "${_image}" "${_template}"
    done
  done
  if [[ ${1:-} == "--purge" ]]
  then
    for _template in "${remove[@]}"
    do
      rm -f -- "${_template}"
    done
    find "${TEMPLATES}" -empty -type d -delete
  fi
  exit
}

main() {
local _val
  case "${1,,}" in
    transfer:was-ok)
      _printf " >>>> {+} {G}the transfer is successful{N} <<<<\n"
      exit 0
      ;;
    install-zt:*)
      _install_zerotier_one ${1#*:}
      exit
      ;;
    host-config-user:*)
      _host_config_user ${1#*:}
      exit
      ;;
    zt-address:get)
      _zt_get_address
      exit
      ;;
    setup::host|setup:host|--setup-host)
      shift
      _setup_host "$@"
      exit
      ;;
    host:list|host::list|list:host|list::host)
      _config_host_list
      exit
      ;;
    # setup remote host
    setup:host:*|setup::host:*|--setup-host:*)
      if _val=$(_extract_param "${1}")
      then
        shift
        _setup_remote_host "${_val}" "$@"
      else
        _abort_script "missing {G}[user@]host{N} for setup::host"
      fi
      exit
      ;;
    config::host|config:host|--config-host|-c)
      shift
      _config_host "$@"
      exit
      ;;
    config::vm|config:vm|--config-vm|--vm|-m)
      shift
      _config_vm "$@"
      exit
      ;;
    overlay:zt:name:*)
      if _val=$(_extract_param "${1}")
      then
        shift
        if [[ ${_val} =~ ^[a-zA-Z][a-zA-Z0-9_-]+$ ]]
        then
          _config_put "/overlay/zt/${_val}/" ""
          _config_put "/overlay/zt/current" "${_val}"
        else
          _abort_script "wrong name for overlay network"
        fi
      fi
      exit
      ;;
    overlay:zt:api:*)
      if _ztnet=$(_config_get "/overlay/zt/current")
      then
        if _val=$(_extract_param "${1}")
        then
          shift
          _config_put "/overlay/zt/${_ztnet}/api" "${_val}"
        else
          _abort_script "missing {G}API{N} key for ZeroTier One overlay network"
        fi
      else
        _abort_script "ZT overlay network not selected (use overlay:zt:name:<NAME> first)"
      fi
      exit
      ;;
    overlay:zt:network:*)
      if _ztnet=$(_config_get "/overlay/zt/current")
      then
        if _val=$(_extract_param "${1}")
        then
          shift
          _config_put "/overlay/zt/${_ztnet}/network" "${_val}"
        else
          _abort_script "missing {G}network{N} ID for ZeroTier One overlay network"
        fi
      else
        _abort_script "ZT overlay network not selected (use overlay:zt:name:<NAME> first)"
      fi
      exit
      ;;
    overlay:zt:verify)
      shift
      _zt_verify_api
      exit
      ;;
    ssh:*)
      if _val=$(_extract_param "${1}")
      then
        shift
        _ssh_to_vm "${_val}" "$@"
      else
        _abort_script "missing {G}name@host{N} for ssh connection"
      fi
      exit
      ;;
    image:backing|image:used|--image-backing|--image-used)
      shift
      _show_backing_templates "$@"
      exit
      ;;
    image:unused|--image-unused)
      shift
      _show_unused_templates "$@"
      ;;
  esac
  _vm_manager "$@"
}

trap '_trap_error $?' ERR

[[ -n ${BASH_SOURCE[0]} ]] && SCRIPT_DIR=$(dirname "$(readlink -f ${BASH_SOURCE[0]})")

_check_var -q HOME
CONFIG="$HOME/.config/$ME"
declare -A _runtime

export TEMPLATES=$(_config_template_location)
export VM_STORAGE=$(_config_storage_location)

export LANG=C
export LC_ALL=C

_IMAGE_REFRESHED=0
#PAYLOAD
#/PAYLOAD

_check_runtime

if [[ "$1" == "me:install" ]]
then
  _install
fi

if [[ "$1" == "me:update" ]]
then
  _self_update
fi

if [[ -z ${_RSKVM_VERSION} ]]
then
  _abort_script "missing {G}\$_RSKVM_VERSION"
fi

if [[ "$1" == "me:version" ]]
then
  _print_line "${_RSKVM_VERSION}"
  exit 0
fi

if [[ -x /usr/bin/rskvm ]]
then
  if _ver=$(/usr/bin/rskvm me:version)
  then
    if [[ ${_ver} -lt ${_RSKVM_VERSION} ]]
    then
      _abort_script "older version (${_ver}) of rskvm detected! Please run: {G}$0 me:install"
    fi
  else
    _abort_script "older version of rskvm detected! Please run: {G}$0 me:install"
  fi
else
  _abort_script "rskvm is not properly installed! Please run: {G}$0 me:install"
fi

main "$@"
# vim: set tabstop=2 shiftwidth=2 expandtab autoindent nosmartindent :
