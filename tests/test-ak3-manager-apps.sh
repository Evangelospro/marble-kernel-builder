#!/usr/bin/env bash
# anykernel.sh manage_manager_apps: install the bundled official manager APK
# when flashed from a running Android, remove other KernelSU-family managers
# only after that succeeded, and in recovery just stage the APK.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

ak="${tmp_dir}/ak"
mkdir -p "${ak}" "${tmp_dir}/bin" "${tmp_dir}/localtmp" "${tmp_dir}/sdcard/marble-kernel-backup"
echo resukisu > "${ak}/marble-manager"
echo com.resukisu.resukisu > "${ak}/marble-manager-package"
printf '%s\n' me.weishu.kernelsu com.rifsxd.ksunext com.sukisu.ultra > "${ak}/marble-other-manager-packages"
echo apk > "${ak}/manager.apk"

# Stub pm: state in ${tmp_dir}/installed (one package per line), log in pm.log.
cat > "${tmp_dir}/bin/pm" <<STUB
#!/bin/sh
state="${tmp_dir}/installed"; touch "\$state"
echo "pm \$*" >> "${tmp_dir}/pm.log"
case "\$1" in
  path) grep -qx "\$2" "\$state" && echo "package:/data/app/\$2/base.apk" && exit 0; exit 1 ;;
  install)
    if [ -e "${tmp_dir}/install-fails" ]; then
      echo "Failure [INSTALL_FAILED_INTERNAL_ERROR]"; exit 1
    fi
    if [ -e "${tmp_dir}/sig-mismatch" ]; then
      rm -f "${tmp_dir}/sig-mismatch"
      echo "Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: signatures do not match]"; exit 1
    fi
    grep -qx com.resukisu.resukisu "\$state" || echo com.resukisu.resukisu >> "\$state"
    echo Success ;;
  uninstall)
    pkg="\$2"; [ "\$2" = --user ] && pkg="\$4"
    grep -qx "\$pkg" "\$state" || { echo "Failure [not installed]"; exit 1; }
    grep -vx "\$pkg" "\$state" > "\$state.new"; mv "\$state.new" "\$state"; echo Success ;;
esac
STUB
chmod +x "${tmp_dir}/bin/pm"

sed -n '/^manage_manager_apps()/,/^}/p' "${repo_root}/ak3/anykernel.sh" |
  sed -e "s|pm=/system/bin/pm;|pm=${tmp_dir}/bin/pm;|" \
      -e "s|/data/local/tmp/|${tmp_dir}/localtmp/|" \
      -e "s|/sdcard/marble-kernel-backup|${tmp_dir}/sdcard/marble-kernel-backup|g" > "${tmp_dir}/fn.sh"
grep -q "pm=${tmp_dir}/bin/pm;" "${tmp_dir}/fn.sh" || fail "could not extract manage_manager_apps"

run() { # $1 = booted|recovery
  local ps_out="1 root init"
  [[ "$1" == booted ]] && ps_out="1 root init
900 root zygote64"
  sh -c "ps() { printf '%s\n' '${ps_out}'; }; ui_print() { echo \"UI: \$*\"; }; AKHOME='${ak}'; . '${tmp_dir}/fn.sh'; manage_manager_apps"
}

# 1) Booted, ROM's KernelSU-Next app present: install ReSukiSU, remove KSU-Next.
printf '%s\n' com.rifsxd.ksunext com.android.settings > "${tmp_dir}/installed"
run booted > "${tmp_dir}/out1"
grep -qx com.resukisu.resukisu "${tmp_dir}/installed" || fail "ReSukiSU app not installed"
! grep -qx com.rifsxd.ksunext "${tmp_dir}/installed" || fail "KernelSU-Next app not removed"
grep -qx com.android.settings "${tmp_dir}/installed" || fail "unrelated app touched"
grep -q 'pm uninstall --user 0 com.rifsxd.ksunext' "${tmp_dir}/pm.log" || fail "old manager not removed with --user 0"

# 2) Signature mismatch on update: replace the app, then succeed.
printf '%s\n' com.resukisu.resukisu > "${tmp_dir}/installed"
touch "${tmp_dir}/sig-mismatch"
run booted > "${tmp_dir}/out2"
grep -q 'different signature' "${tmp_dir}/out2" || fail "signature mismatch not handled"
grep -qx com.resukisu.resukisu "${tmp_dir}/installed" || fail "app missing after signature replacement"

# 3) Install fails: old managers must stay.
printf '%s\n' com.rifsxd.ksunext > "${tmp_dir}/installed"
touch "${tmp_dir}/install-fails"
run booted > "${tmp_dir}/out3"
grep -qx com.rifsxd.ksunext "${tmp_dir}/installed" || fail "old manager removed although install failed"
grep -q 'install failed' "${tmp_dir}/out3" || fail "install failure not reported"

# 4) Recovery: no pm calls, APK staged on /sdcard.
: > "${tmp_dir}/pm.log"
run recovery > "${tmp_dir}/out4"
[[ ! -s "${tmp_dir}/pm.log" ]] || fail "pm used in recovery"
[[ -f "${tmp_dir}/sdcard/marble-kernel-backup/resukisu-manager.apk" ]] || fail "APK not staged in recovery"

echo "AK3 manager app tests passed"
