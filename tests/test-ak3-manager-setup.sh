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
  list)
    # pm list packages -f: package:<apk path>=<package>
    while read -r p; do
      grep -qx "\$p" "${tmp_dir}/hidden" 2>/dev/null && continue
      echo "package:${tmp_dir}/apps/\$p/base.apk=\$p"
    done < "\$state" ;;
  path)
    [ "\$2" = android ] && { echo package:/system/framework/framework-res.apk; exit 0; }
    grep -qx "\$2" "${tmp_dir}/hidden" 2>/dev/null && exit 1
    grep -qx "\$2" "\$state" && echo "package:${tmp_dir}/app/base.apk" && exit 0; exit 1 ;;
  install)
    [ -e "${tmp_dir}/install-fails" ] && { echo "Failure [INSTALL_FAILED_INTERNAL_ERROR]"; exit 1; }
    grep -qx com.resukisu.resukisu "\$state" || echo com.resukisu.resukisu >> "\$state"
    echo Success ;;
  uninstall)
    pkg="\$2"; [ "\$2" = --user ] && pkg="\$4"
    grep -qx "\$pkg" "${tmp_dir}/uninstall-blocked" 2>/dev/null && { echo "Failure [DELETE_FAILED_INTERNAL_ERROR]"; exit 1; }
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
      -e "s|^MARBLE_PKGLIST=.*|MARBLE_PKGLIST=${tmp_dir}/packages.list;|" \
      -e "s|^MARBLE_APPDIR=.*|MARBLE_APPDIR=${tmp_dir}/dataapp;|" \
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
  sed -e "s|/data/adb/|${adb}/|g" -e "s|/data/local/tmp/|${tmp_dir}/localtmp/|g" \
      -e "s|/data/system/packages.list|${tmp_dir}/packages.list|g" -e "s|/data/app/|${tmp_dir}/dataapp/|g" \
      "${hook}" > "${tmp_dir}/hook.sh"
  # It deletes "$0"; emulate by deleting the real hook when the copy is gone.
  PATH="${bin}:${PATH}" sh "${tmp_dir}/hook.sh"
  [[ -e "${tmp_dir}/hook.sh" ]] || rm -f "${hook}"
}
reset_adb() {
  rm -rf "${tmp_dir}/data" "${tmp_dir}/pm.log" "${tmp_dir}/ksud-install.log" "${tmp_dir}/install-fails" \
    "${tmp_dir}/hidden" "${tmp_dir}/uninstall-blocked" "${tmp_dir}/dataapp" "${tmp_dir}/packages.list"
  mkdir -p "${adb}/ksu/bin" "${adb}/modules/modA" "${adb}/modules/modB"
  echo old-ksunext-ksud > "${adb}/ksud"
  touch "${adb}/modules/modB/disable"
  printf '%s\n' com.rifsxd.ksunext com.android.settings > "${tmp_dir}/installed"
}

# Installed apps' extracted native libs: KernelSU-family managers ship libksud.so.
for p in com.resukisu.resukisu com.spoofed.k9x2; do
  mkdir -p "${tmp_dir}/apps/${p}/lib/arm64" && touch "${tmp_dir}/apps/${p}/lib/arm64/libksud.so"
done
mkdir -p "${tmp_dir}/apps/com.android.settings/lib/arm64" && touch "${tmp_dir}/apps/com.android.settings/lib/arm64/libfoo.so"

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

# ── H: /data/adb unreachable (e.g. recovery without /data) -> stop before writing ──
pre() { # zipname
  sh -c "ui_print() { :; }; abort() { exit 9; }; mountpoint() { return 1; }; mount() { return 1; }
    AKHOME='${ak}'; ZIPFILE='/sdcard/$1'
    marble_force_requested() { case \"\$(basename \"\${ZIPFILE}\" .zip)\" in *-force) return 0;; esac; return 1; }
    . '${tmp_dir}/fn.sh'; MARBLE_ADB='${tmp_dir}/no-such-data/adb'; precheck_manager_data"
}
rc=0; pre k.zip || rc=$?
[[ ${rc} -eq 9 ]] || fail "H: flash must stop when /data/adb is not accessible (rc=${rc})"
pre k-force.zip || fail "H: force flash must continue"
rc=0
sh -c "ui_print() { :; }; abort() { exit 9; }; AKHOME='${ak}'; . '${tmp_dir}/fn.sh'; MARBLE_ADB='${adb}'; precheck_manager_data" || rc=$?
[[ ${rc} -eq 0 ]] || fail "H: accessible /data/adb must pass the precheck"

# ── I: dry run (-check.zip) reports the plan and writes nothing ──
reset_adb
before="$(cd "${adb}" && find . | sort | md5sum)"
sed -n '/^marble_dry_run_requested()/,/^# Refuse to flash unless/p' "${repo_root}/ak3/anykernel.sh" | sed '$d' > "${tmp_dir}/dry.sh"
sh -c "ui_print() { echo \"UI: \$*\"; }; AKHOME='${ak}'; ZIPFILE='/sdcard/k-check.zip'
  . '${tmp_dir}/fn.sh'; MARBLE_ADB='${adb}'; . '${tmp_dir}/dry.sh'
  marble_dry_run_requested && marble_dry_run_report" > "${tmp_dir}/outI" || fail "I: dry run not detected"
grep -q 'DRY RUN' "${tmp_dir}/outI" || fail "I: dry run banner missing"
grep -q 'Would move ksud/ksu' "${tmp_dir}/outI" || fail "I: planned ksud move not reported"
grep -q 'disable 1 module' "${tmp_dir}/outI" || fail "I: planned module disabling not reported"
[[ "$(cd "${adb}" && find . | sort | md5sum)" == "${before}" ]] || fail "I: dry run changed /data/adb"
sh -c ". '${tmp_dir}/dry.sh'; ZIPFILE=/sdcard/k.zip; marble_dry_run_requested" && fail "I: normal zip treated as dry run"
awk '/^precheck_manager_data;/{p=NR} /^if marble_dry_run_requested/{d=NR} /^backup_current_boot;/{b=NR} /^write_boot;/{w=NR} END{exit !(p<d && d<b && b<w)}' "${repo_root}/ak3/anykernel.sh" ||
  fail "I: dry run must exit after all checks and before backup/write"

# ── J: a renamed ("spoofed") KernelSU-Next with a random package name is
#       found by its libksud.so and removed; BakaSU itself and normal apps stay ──
for mode in booted hook; do
  reset_adb
  printf '%s\n' com.spoofed.k9x2 com.android.settings > "${tmp_dir}/installed"
  if [[ "${mode}" == booted ]]; then
    flash booted > /dev/null
  else
    flash recovery > /dev/null
    run_hook
  fi
  ! grep -qx com.spoofed.k9x2 "${tmp_dir}/installed" || fail "J(${mode}): spoofed manager not removed"
  grep -qx com.resukisu.resukisu "${tmp_dir}/installed" || fail "J(${mode}): BakaSU removed or not installed"
  grep -qx com.android.settings "${tmp_dir}/installed" || fail "J(${mode}): unrelated app removed"
done

# ── K: KernelSU-Next hidden from pm queries by an app hider (Hide My Applist):
#       found via packages.list and /data/app, removed anyway ──
for mode in booted hook; do
  reset_adb
  echo com.rifsxd.ksunext > "${tmp_dir}/hidden"
  printf 'com.rifsxd.ksunext 10234 0 /data/user/0/com.rifsxd.ksunext default:targetSdkVersion=35 3003\n' > "${tmp_dir}/packages.list"
  mkdir -p "${tmp_dir}/dataapp/~~Ab1==/com.rifsxd.ksunext-Qx9==/lib/arm64"
  touch "${tmp_dir}/dataapp/~~Ab1==/com.rifsxd.ksunext-Qx9==/lib/arm64/libksud.so"
  if [[ "${mode}" == booted ]]; then
    flash booted > "${tmp_dir}/outK"
  else
    flash recovery > /dev/null
    run_hook
  fi
  ! grep -qx com.rifsxd.ksunext "${tmp_dir}/installed" || fail "K(${mode}): hidden KernelSU-Next not removed"
  grep -qx com.android.settings "${tmp_dir}/installed" || fail "K(${mode}): unrelated app removed"
done

# ── L: removal blocked -> reported, not silently skipped ──
reset_adb
echo com.rifsxd.ksunext > "${tmp_dir}/uninstall-blocked"
flash booted > "${tmp_dir}/outL"
grep -q 'could not remove com.rifsxd.ksunext' "${tmp_dir}/outL" || fail "L: blocked removal not reported"

echo "AK3 manager setup tests passed"
