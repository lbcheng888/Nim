# Utilities used in CI pipelines and tooling to avoid duplication.
# Avoid top-level statements.
# Prefer nim scripts whenever possible.
# functions starting with `_` are considered internal, less stable.

echo_run () {
  # echo's a command before running it, which helps understanding logs
  echo ""
  echo "cmd: $@" # in azure we could also use this: echo '##[section]"$@"'
  "$@"
}

nimGetLastCommit() {
  git log --no-merges -1 --pretty=format:"%s"
}

nimIsCiSkip(){
  # D20210329T004830:here refs https://github.com/microsoft/azure-pipelines-agent/issues/2944
  # `--no-merges` is needed to avoid merge commits which occur for PR's.
  # $(Build.SourceVersionMessage) is not helpful
  # nor is `github.event.head_commit.message` for github actions.
  # Note: `[skip ci]` is now handled automatically for github actions, see https://github.blog/changelog/2021-02-08-github-actions-skip-pull-request-and-push-workflows-with-skip-ci/
  commitMsg=$(nimGetLastCommit)
  echo commitMsg: "$commitMsg"
  if [[ $commitMsg == *"[skip ci]"* ]]; then
    echo "skipci: true"
    return 0
  else
    echo "skipci: false"
    return 1
  fi
}

nimInternalInstallDepsWindows(){
  echo_run mkdir dist
  echo_run curl -L https://nim-lang.org/download/mingw64.7z -o dist/mingw64.7z
  echo_run curl -L https://nim-lang.org/download/dlls.zip -o dist/dlls.zip
  echo_run 7z x dist/mingw64.7z -odist
  echo_run 7z x dist/dlls.zip -obin
}

nimInternalBuildKochAndRunCI(){
  echo_run nim c koch
  if ! echo_run ./koch runCI; then
    echo_run echo "runCI failed"
    echo_run nim r tools/ci_testresults.nim
    return 1
  fi
}

nimDefineVars(){
  . config/build_config.txt
  nim_csources=bin/nim_csources_$nim_csourcesHash
}

_nimNumCpu(){
  # linux: $(nproc)
  # FreeBSD | macOS: $(sysctl -n hw.ncpu)
  # OpenBSD: $(sysctl -n hw.ncpuonline)
  # windows: $NUMBER_OF_PROCESSORS ?
  if env | grep -q '^NIMCORES='; then
    echo $NIMCORES
  else
    echo $(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || 1)
  fi
}

_nimBuildCsourcesIfNeeded(){
  # Prefer the generated makefile for speed and compatibility with existing callers.
  # Fall back to build.sh when a csources checkout is missing the makefile.
  unamestr=$(uname)
  # uname values: https://en.wikipedia.org/wiki/Uname
  if [ "$unamestr" = 'FreeBSD' ]; then
    makeX=gmake
  elif [ "$unamestr" = 'OpenBSD' ]; then
    makeX=gmake
  elif [ "$unamestr" = 'NetBSD' ]; then
    makeX=gmake
  elif [ "$unamestr" = 'CROSSOS' ]; then
    makeX=gmake
  elif [ "$unamestr" = 'SunOS' ]; then
    makeX=gmake
  else
    makeX=make
  fi
  nCPU=$(_nimNumCpu)
  if test -f "$nim_csourcesDir/makefile"; then
    echo_run which $makeX
    # parallel jobs (5X faster on 16 cores: 10s instead of 50s)
    echo_run $makeX -C $nim_csourcesDir -j $((nCPU + 2)) -l $nCPU "$@"
  elif test -f "$nim_csourcesDir/build.sh"; then
    echo "$nim_csourcesDir/makefile missing; falling back to build.sh"

    # build.sh accepts a smaller argument surface than the makefile path.
    while [ "$#" -gt 0 ]; do
      case "$1" in
        CC=*)
          buildShCC=${1#CC=}
          ;;
        CFLAGS=*)
          buildShCFlags=${1#CFLAGS=}
          ;;
        CPPFLAGS=*)
          buildShCppFlags=${1#CPPFLAGS=}
          ;;
        LDFLAGS=*)
          buildShLdFlags=${1#LDFLAGS=}
          ;;
        ucpu=*)
          buildShCpu=${1#ucpu=}
          ;;
        uos=*)
          buildShOs=${1#uos=}
          ;;
        uosname=*)
          buildShOsName=${1#uosname=}
          ;;
        *)
          echo "Error: unsupported csources_v3 build.sh fallback argument: $1" >&2
          return 1
          ;;
      esac
      shift
    done

    (
      set -e
      cd "$nim_csourcesDir"

      if [ "${buildShCC+set}" = set ]; then
        CC=$buildShCC
        export CC
      fi
      if [ "${buildShCFlags+set}" = set ]; then
        CFLAGS=$buildShCFlags
        export CFLAGS
      fi
      if [ "${buildShCppFlags+set}" = set ]; then
        CPPFLAGS=$buildShCppFlags
        export CPPFLAGS
      fi
      if [ "${buildShLdFlags+set}" = set ]; then
        LDFLAGS=$buildShLdFlags
        export LDFLAGS
      fi

      set --
      if command -v sem >/dev/null 2>&1; then
        set -- "$@" --parallel "$nCPU"
      fi
      if [ "${buildShOs+set}" = set ]; then
        set -- "$@" --os "$buildShOs"
      fi
      if [ "${buildShCpu+set}" = set ]; then
        set -- "$@" --cpu "$buildShCpu"
      fi
      if [ "${buildShOsName+set}" = set ]; then
        set -- "$@" --osname "$buildShOsName"
      fi

      echo_run sh build.sh "$@"
    )
  else
    echo "Error: missing both $nim_csourcesDir/makefile and $nim_csourcesDir/build.sh" >&2
    return 1
  fi
  # keep $nim_csources in case needed to investigate bootstrap issues
  # without having to rebuild
  echo_run cp bin/nim $nim_csources
}

nimCiSystemInfo(){
  nimDefineVars
  echo_run eval echo '$'nim_csources
  echo_run pwd
  echo_run date
  echo_run uname -a
  echo_run git log --no-merges -1 --pretty=oneline
  echo_run eval echo '$'PATH
  echo_run gcc -v
  echo_run node -v
  echo_run make -v
}

nimCsourcesHash(){
  nimDefineVars
  echo $nim_csourcesHash
}

nimBuildCsourcesIfNeeded(){
  # goal: allow cachine each tagged version independently
  # to avoid rebuilding, so that tools like `git bisect`
  # can grab a cached past version without rebuilding.
  nimDefineVars
  (
    set -e
    # avoid polluting caller scope with internal variable definitions.
    if test -f "$nim_csources"; then
      echo "$nim_csources exists."
    else
      if test -d "$nim_csourcesDir"; then
        echo "$nim_csourcesDir exists."
      else
        # Note: using git tags would allow fetching just what's needed, unlike git hashes, e.g.
        # via `git clone -q --depth 1 --branch $tag $nim_csourcesUrl`.
        echo_run git clone -q --depth 1 -b $nim_csourcesBranch \
            $nim_csourcesUrl "$nim_csourcesDir"
        # old `git` versions don't support -C option, using `cd` explicitly:
        echo_run cd "$nim_csourcesDir"
        echo_run git checkout $nim_csourcesHash
        echo_run cd "$OLDPWD"
        # if needed we could also add: `git reset --hard $nim_csourcesHash`
      fi
      _nimBuildCsourcesIfNeeded "$@"
    fi

    echo_run rm -f bin/nim
      # fixes bug #17913, but it's unclear why it's needed, maybe specific to MacOS Big Sur 11.3 on M1 arch?
    echo_run cp $nim_csources bin/nim
    echo_run $nim_csources -v
  )
}
