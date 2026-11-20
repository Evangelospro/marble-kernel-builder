#!/usr/bin/env bash
# anykernel.sh setup_manager (Magisk-style manager handoff):
#  - switching from another fork (e.g. ROM built-in KernelSU-Next) moves its
#    /data/adb userspace aside, disables modules, installs the bundled ksud and
#    stages the app + a one-shot boot-completed.d hook (works from recovery);
#  - the hook installs the app, removes other manager apps only after that,
#    runs `ksud install`, and deletes itself (keeps itself for retry on failure);
#  - from a running Android the app is installed right away;
#  - reflashing the same manager changes nothing.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

adb="${tmp_dir}/data/adb"
ak="${tmp_dir}/ak"
bin="${tmp_dir}/bin"
mkdir -p "${ak}" "${bin}" "${tmp_dir}/localtmp" "${tmp_dir}/app/lib/arm64"

# Zip contents
echo bakasu > "${ak}/marble-manager"
echo com.resukisu.resukisu > "${ak}/marble-manager-package"
printf '%s\n' me.weishu.kernelsu com.rifsxd.ksunext com.sukisu.ultra > "${ak}/marble-other-manager-packages"
echo apk > "${ak}/manager.apk"
printf '#!/bin/sh\necho new-ksud\n' > "${ak}/ksud"
echo "v4.2.0-rc3 (35262)" > "${ak}/marble-manager-version"

# Installed app's native libs (used by the hook for `ksud install`)
printf '#!/bin/sh\necho "ksud $*" >> "%s/ksud-install.log"\n' "${tmp_dir}" > "${tmp_dir}/app/lib/arm64/libksud.so"
chmod +x "${tmp_dir}/app/lib/arm64/libksud.so"
touch "${tmp_dir}/app/lib/arm64/libadbroot.so"

# Stub pm: installed packages in ${tmp_dir}/installed; log in pm.log.
cat > "${bin}/pm" <<STUB
#!/bin/sh
state="${tmp_dir}/installed"; touch "\$state"
echo "pm \$*" >> "${tmp_dir}/pm.log"
case "\$1" in
  path)
    [ "\$2" = android ] && { echo package:/system/framework/framework-res.apk; exit 0; }
    grep -qx "\$2" "\$state" && echo "package:${tmp_dir}/app/base.apk" && exit 0; exit 1 ;;
  install)
    [ -e "${tmp_dir}/install-fails" ] && { echo "Failure [INSTALL_FAILED_INTERNAL_ERROR]"; exit 1; }
    grep -qx com.resukisu.resukisu "\$state" || echo com.resukisu.resukisu >> "\$state"
    echo Success ;;
  uninstall)
    pkg="\$2"; [ "\$2" = --user ] && pkg="\$4"
    grep -qx "\$pkg" "\$state" || { echo "Failure"; exit 1; }
    grep -vx "\$pkg" "\$state" > "\$state.new"; mv "\$state.new" "\$state"; echo Success ;;
esac
STUB
printf '#!/bin/sh\necho 1\n' > "${bin}/getprop"
printf '#!/bin/sh\n:\n' > "${bin}/sleep"
chmod +x "${bin}/pm" "${bin}/getprop" "${bin}/sleep"

# Extract the manager block from anykernel.sh, pointing paths at the sandbox.
sed -n '/^# ── Root manager userspace and app/,/^ui_print "Supported devices/p' "${repo_root}/ak3/anykernel.sh" |
  sed -e '$d' \
      -e "s|^MARBLE_ADB=/data/adb;|MARBLE_ADB=${adb};|" \
      -e "s|pm=/system/bin/pm;|pm=${bin}/pm;|" \
      -e "s|/data/local/tmp/|${tmp_dir}/localtmp/|g" > "${tmp_dir}/fn.sh"
grep -q "MARBLE_ADB=${adb};" "${tmp_dir}/fn.sh" || fail "could not extract the manager block"

flash() { # $1 = booted|recovery
  local zygote=""
  [[ "$1" == booted ]] && zygote="900 root zygote64"
  PATH="${bin}:${PATH}" sh -c "ps() { echo '1 root init'; [ -n '${zygote}' ] && echo '${zygote}'; true; }
    ui_print() { echo \"UI: \$*\"; }; AKHOME='${ak}'; . '${tmp_dir}/fn.sh'; setup_manager"
}
hook="${adb}/boot-completed.d/marble-install-manager.sh"
run_hook() {
  # The hook hardcodes /data/adb paths; run a sandboxed copy.
  sed -e "s|/data/adb/|${adb}/|g" -e "s|/data/local/tmp/|${tmp_dir}/localtmp/|g" "${hook}" > "${tmp_dir}/hook.sh"
  # It deletes "$0"; emulate by deleting the real hook when the copy is gone.
  PATH="${bin}:${PATH}" sh "${tmp_dir}/hook.sh"
  [[ -e "${tmp_dir}/hook.sh" ]] || rm -f "${hook}"
}
reset_adb() {
  rm -rf "${tmp_dir}/data" "${tmp_dir}/pm.log" "${tmp_dir}/ksud-install.log" "${tmp_dir}/install-fails"
  mkdir -p "${adb}/ksu/bin" "${adb}/modules/modA" "${adb}/modules/modB"
  echo old-ksunext-ksud > "${adb}/ksud"
  touch "${adb}/modules/modB/disable"
  printf '%s\n' com.rifsxd.ksunext com.android.settings > "${tmp_dir}/installed"
}

# ── A: recovery flash over the ROM's built-in KernelSU-Next ──
reset_adb
flash recovery > "${tmp_dir}/outA"
backup="$(find "${adb}/marble-backup" -mindepth 1 -maxdepth 1 -type d)"
[[ "$(cat "${backup}/ksud")" == old-ksunext-ksud ]] || fail "A: old ksud not backed up"
[[ -d "${backup}/ksu" && ! -e "${adb}/ksu" ]] || fail "A: old /data/adb/ksu not moved"
[[ -e "${adb}/modules/modA/disable" ]] || fail "A: module not disabled"
[[ "$(cat "${backup}/disabled-modules.txt")" == modA ]] || fail "A: disabled list wrong"
cmp -s "${ak}/ksud" "${adb}/ksud" || fail "A: bundled ksud not installed"
[[ -x "${adb}/ksud" ]] || fail "A: ksud not executable"
[[ -x "${hook}" ]] || fail "A: first-boot hook not staged"
cmp -s "${ak}/manager.apk" "${adb}/marble-pending/manager.apk" || fail "A: APK not staged"
[[ "$(cat "${adb}/.marble-manager")" == bakasu ]] || fail "A: marker not written"
[[ ! -e "${tmp_dir}/pm.log" ]] || fail "A: pm used in recovery"

# ── B: first boot runs the hook ──
run_hook
grep -qx com.resukisu.resukisu "${tmp_dir}/installed" || fail "B: app not installed by hook"
! grep -qx com.rifsxd.ksunext "${tmp_dir}/installed" || fail "B: old manager app not removed"
grep -qx com.android.settings "${tmp_dir}/installed" || fail "B: unrelated app touched"
grep -q "ksud install --libadbroot ${tmp_dir}/app/lib/arm64/libadbroot.so" "${tmp_dir}/ksud-install.log" ||
  fail "B: ksud install not run"
[[ ! -e "${adb}/marble-pending" && ! -e "${hook}" ]] || fail "B: hook did not clean up"

# ── C: hook install failure keeps the old manager and retries next boot ──
reset_adb
flash recovery > /dev/null
touch "${tmp_dir}/install-fails"
run_hook
grep -qx com.rifsxd.ksunext "${tmp_dir}/installed" || fail "C: old manager removed although install failed"
[[ -e "${hook}" && -d "${adb}/marble-pending" ]] || fail "C: hook should stay for a retry"
cp "${adb}/marble-pending.log" "${tmp_dir}/logC"

# ── D: flash from running Android installs the app immediately ──
reset_adb
flash booted > "${tmp_dir}/outD"
grep -qx com.resukisu.resukisu "${tmp_dir}/installed" || fail "D: app not installed immediately"
! grep -qx com.rifsxd.ksunext "${tmp_dir}/installed" || fail "D: old manager app not removed"
[[ -x "${hook}" ]] || fail "D: hook not staged to finish ksud install"

# ── E: reflashing the same manager (e.g. a newer build) installs the exact
#       bundled ksud + app, but does not back up or disable modules ──
reset_adb
echo bakasu > "${adb}/.marble-manager"
echo older-bakasu-ksud > "${adb}/ksud"
printf '%s\n' com.resukisu.resukisu > "${tmp_dir}/installed"
flash recovery > "${tmp_dir}/outE"
cmp -s "${ak}/ksud" "${adb}/ksud" || fail "E: older ksud of the same manager not replaced by the exact build"
[[ -x "${hook}" ]] || fail "E: exact app build not staged"
[[ ! -e "${adb}/marble-backup" ]] || fail "E: same-manager reflash made a backup"
[[ ! -e "${adb}/modules/modA/disable" ]] || fail "E: modules disabled on same-manager reflash"
grep -q 'v4.2.0-rc3 (35262)' "${tmp_dir}/outE" || fail "E: version not reported"
# The hook must reinstall although the app is already installed (other version).
run_hook
grep -q '^pm install -r -d ' "${tmp_dir}/pm.log" || fail "E: hook skipped installing over an existing app"
[[ ! -e "${hook}" ]] || fail "E: hook did not finish"

# ── F: no exact build bundled -> nothing installed, old userspace still retired ──
reset_adb
rm -f "${ak}/ksud" "${ak}/manager.apk"
flash recovery > "${tmp_dir}/outF"
[[ ! -e "${adb}/ksud" ]] || fail "F: a ksud was installed without an exact build"
[[ ! -e "${hook}" ]] || fail "F: hook staged without an app"
[[ -n "$(find "${adb}/marble-backup" -name ksud)" ]] || fail "F: foreign ksud not moved aside"
grep -q 'No exact bakasu build bundled' "${tmp_dir}/outF" || fail "F: missing notice"

grep -q "will retry next boot" "${tmp_dir}/logC" || fail "C: hook log missing retry note"

# ── G: a marker written under the old name (resukisu) is the same manager ──
reset_adb
rm -f "${ak}/ksud"; printf '#!/bin/sh\necho new-ksud\n' > "${ak}/ksud"; echo apk > "${ak}/manager.apk"
echo resukisu > "${adb}/.marble-manager"
flash recovery > "${tmp_dir}/outG"
[[ ! -e "${adb}/marble-backup" ]] || fail "G: old-name marker treated as a manager switch"
[[ ! -e "${adb}/modules/modA/disable" ]] || fail "G: modules disabled for an old-name marker"
[[ "$(cat "${adb}/.marble-manager")" == bakasu ]] || fail "G: marker not migrated to the new name"

echo "AK3 manager setup tests passed"
