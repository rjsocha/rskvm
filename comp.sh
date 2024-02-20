__rskvm_bash() {
  local cur prev words cword split;
  _init_completion -s || return;
  {
    echo C: $cur
    echo P: $prev
    echo W: $words
    echo CW: $cword
    echo S: $split
    echo CR: ${#COMPREPLY[@]}
    echo CWORDS: "${COMP_WORDS[@]}"
  } >>~/.comp.log
  COMPREPLY=()

  if [[ ${cur} =~ ^\+([a-z][a-z0-9-]+/[a-z0-9-]+)@ ]] || [[ ${cur} =~ ^\+([a-z][a-z0-9-]+)@ ]]
  then
    echo "XXXX" >>~/.comp.log
    local host hosts=()
    for host in $(find ~/.config/rskvm/host/ -maxdepth 1 -mindepth 1 -type d -printf "%f\n")
    do
      hosts+="+${BASH_REMATCH[1]}@${host} "
    done
    echo "AA: ${hosts}" >>~/.comp.log
    COMPREPLY=($(compgen -W "${hosts}" -- "${cur}"))
  elif [[ ${cur} =~ ^\+([a-z][a-z0-9-]+)/ ]]
  then
    local ll xx=()
    for ll in $(find ~/.config/rskvm/image/alias/by-name/ -maxdepth 1 -mindepth 1 -printf "%f\n")
    do
      xx+="+${BASH_REMATCH[1]}/${ll} "
    done
    COMPREPLY=($(compgen -W "${xx}" -- "${cur}"))
  elif [[ ${cur::2} == "--" ]]
  then
    COMPREPLY=($(compgen -W "--image-list --image-update --image-unused --image-used --start --stop --console --full --verbose --no-config --update --remote-update --nested --link --prefer-uefi --bios --uefi --query --protect --unprotect --hide --unhide --exists --rebase --no-boot --boot" -- "${cur}"))
  elif [[ ${cur::1} == "-" ]]
  then
    if [[ -d ~/.ssh/rskvm.d ]]
    then
      local _host _hosts
      for _host in $(find ~/.ssh/rskvm.d -maxdepth 1 -mindepth 1 -type f -printf "%f\n")
      do
        if [[ ${cword} -gt 1 ]]
        then
          local _n _c=0
          for _n in ${COMP_WORDS[@]}
          do
            echo "check: -$_host@ $_n" >>~/.comp.log
            if [[ ${_n} =~ -${_host}(@|$) ]]
            then
              echo "ignore: $_host" >>~/.comp.log
              _c=1
              break
            fi
          done
          if [[ $_c -eq 1 ]]
          then
            continue
          fi
        fi
        _hosts+="-${_host} "
      done
      local _words=($(compgen -W "${_hosts}" -- "$cur"))
      echo "${_hosts}  : ${_words[@]} N:${#_words[@]}" >>~/.comp.log
      if [[ ${#_words[@]} -eq 1 ]]
      then
        local _host=${_words[@]}
        _host="${_host:1}"
        _host=$(head -n1 ~/.ssh/rskvm.d/${_host})
        echo $_host >>~/.comp.log
        if [[ ${_host} =~ ^\#@ ]]
        then
          if [[ ${_host:1} != "@localhost" ]]
          then
            _words=( "${_words[@]}${_host:1}" )
          fi
        fi
      fi
      COMPREPLY=( ${_words[@]} )
    fi
  fi
}
complete -F __rskvm_bash rskvm
