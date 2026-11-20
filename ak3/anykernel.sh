properties() { '
kernel.string=Marble Kernel for Poco F5 / Redmi Note 12 Turbo
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=marble
device.name2=marblein
supported.versions=
supported.patchlevels=
'; }

block=boot;
is_slot_device=auto;
ramdisk_compression=auto;
patch_vbmeta_flag=auto;

. tools/ak3-core.sh;

backup_current_boot() {
  backup_dir="/sdcard/marble-kernel-backup";
  slot_name="${SLOT:-noslot}";
  stamp="$(date +%Y%m%d-%H%M%S 2>/dev/null || date +%s)";
  backup_img="${backup_dir}/boot-marble-${slot_name}-${stamp}.img";
  backup_txt="${backup_dir}/boot-marble-${slot_name}-${stamp}.txt";

  ui_print " ";
  ui_print "Backing up current boot image...";
  mkdir -p "$backup_dir" || abort "Unable to create ${backup_dir}. Aborting...";

  if [ ! -s "$BOOTIMG" ]; then
    abort "Dumped boot image is missing. Backup failed; aborting for safety.";
  fi;

  cp -f "$BOOTIMG" "$backup_img" || abort "Unable to save boot backup. Aborting...";
  {
    echo "device=marble/marblein";
    echo "slot=${slot_name}";
    echo "source_block=${BLOCK}";
    echo "created=${stamp}";
    echo "backup=${backup_img}";
  } > "$backup_txt" 2>/dev/null || true;

  ui_print "Backup saved:";
  ui_print "  ${backup_img}";
}

# "X.Y.Z-..." release from the "Linux version <release> (" banner of a raw
# kernel image or of `uname -r`-style text.
banner_release() {
  [ -f "$1" ] || return 0;
  strings "$1" 2>/dev/null | sed -n 's/^.*Linux version \([0-9][0-9]*\.[0-9][0-9]*[^ ]*\) (.*$/\1/p' | head -n 1;
}
release_series() { echo "$1" | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p'; }
# 12-hex kernel source commit from a release like 5.10.269-gki-g658b84f13496(-dirty)
release_commit() { echo "$1" | sed -n 's/^.*-g\([0-9a-f]\{12\}\).*$/\1/p'; }

marble_force_requested() {
  case "$(basename "${ZIPFILE:-x.zip}" .zip)" in
    *-force) return 0;;
  esac;
  [ -f /tmp/.marble-force-flash ];
}

# Refuse to flash unless the new Image matches the ROM's kernel: same series
# (5.10 vs 6.6) AND the same kernel source commit. The ROM's vendor_boot /
# vendor_dlkm modules are built against exactly that kernel; a different series
# or commit can make them fail to load, and the phone bootloops. Anything that
# cannot be verified also stops the flash. Override (e.g. to repair a slot that
# already holds a wrong kernel): rename the zip to end in "-force.zip".
check_kernel_series() {
  new_rel="$(banner_release "$AKHOME/Image")";
  cur_rel="$(banner_release "$SPLITIMG/kernel")";
  cur_src="boot image";
  if [ -z "$cur_rel" ]; then
    cur_rel="$(uname -r 2>/dev/null)";
    cur_src="running kernel";
  fi;
  new_ver="$(release_series "$new_rel")"; cur_ver="$(release_series "$cur_rel")";
  new_sha="$(release_commit "$new_rel")"; cur_sha="$(release_commit "$cur_rel")";

  ui_print " ";
  ui_print "New kernel     : ${new_rel:-unknown}";
  ui_print "Current kernel : ${cur_rel:-unknown} (${cur_src})";

  problem="";
  if [ -z "$new_ver" ] || [ -z "$cur_ver" ]; then
    problem="could not read both kernel versions";
  elif [ "$new_ver" != "$cur_ver" ]; then
    problem="kernel ${new_ver} in this zip, but the ROM runs ${cur_ver}";
  elif [ -z "$new_sha" ] || [ -z "$cur_sha" ]; then
    problem="could not read both kernel source commits";
  elif [ "$new_sha" != "$cur_sha" ]; then
    problem="built from kernel commit ${new_sha}, but the ROM's kernel is ${cur_sha}";
  fi;
  [ "$problem" ] || { ui_print "Kernel matches the ROM (${new_ver}, commit ${new_sha})."; return 0; };

  if marble_force_requested; then
    ui_print "WARNING: ${problem}.";
    ui_print "Continuing only because force flash was requested.";
    return 0;
  fi;
  ui_print " ";
  ui_print "STOP: ${problem}.";
  ui_print "The ROM's kernel modules are built for its own";
  ui_print "kernel; a mismatch can bootloop the phone.";
  ui_print "Rebuild with source_ref=${cur_sha:-<your ROM's kernel commit>}.";
  ui_print "Only if you know the boot slot holds a wrong";
  ui_print "kernel: rename this zip to end in -force.zip.";
  abort "Kernel does not match the ROM. Nothing was flashed.";
}

# ── Root manager userspace and app (Magisk-style) ───────────────────────────
# KernelSU-family kernels inject a *blocking* init step:
#   on post-fs-data: exec u:r:su:s0 root -- /data/adb/ksud post-fs-data
# If /data/adb/ksud belongs to another fork (e.g. the ROM's built-in
# KernelSU-Next while this zip carries BakaSU), boot can hang at the logo.
# So when the manager changes we:
#   1. move the old /data/adb/ksud + /data/adb/ksu to /data/adb/marble-backup/
#      and disable modules for the first boot (they were set up by another fork);
#   2. install this kernel's own ksud (extracted from its official app at build
#      time), so root works from the first boot;
#   3. stage the official app plus a one-shot boot-completed.d script: on first
#      boot the new ksud runs it once Android is up; it installs the app, removes
#      other KernelSU-family manager apps, runs `ksud install` (what the app does
#      on first launch) and deletes itself. Works for recovery flashes too.
# When flashed from a running Android the app is also installed right away.

MARBLE_ADB=/data/adb;
MARBLE_PENDING=$MARBLE_ADB/marble-pending;
MARBLE_HOOK=$MARBLE_ADB/boot-completed.d/marble-install-manager.sh;

marble_android_running() {
  ps -A 2>/dev/null | grep -q '[z]ygote' || ps 2>/dev/null | grep -q '[z]ygote';
}

# Install the bundled ksud as /data/adb/ksud.
marble_install_ksud() {
  [ -f $AKHOME/ksud ] || return 1;
  cp -f $AKHOME/ksud $MARBLE_ADB/ksud || return 1;
  chown 0:0 $MARBLE_ADB/ksud 2>/dev/null;
  chmod 755 $MARBLE_ADB/ksud;
  # ksu_file is what `ksud install` uses; it only exists once a KernelSU-family
  # kernel has patched the policy. Otherwise keep the default adb_data_file
  # label, which the kernel also lets init execute.
  chcon u:object_r:ksu_file:s0 $MARBLE_ADB/ksud 2>/dev/null ||
    chcon u:object_r:adb_data_file:s0 $MARBLE_ADB/ksud 2>/dev/null;
  return 0;
}

# Stage the app and the one-shot first-boot hook.
marble_stage_first_boot() {
  pkg="$1";
  [ -f $AKHOME/manager.apk ] && [ "$pkg" ] || return 1;
  mkdir -p $MARBLE_PENDING $MARBLE_ADB/boot-completed.d || return 1;
  cp -f $AKHOME/manager.apk $MARBLE_PENDING/manager.apk || return 1;
  echo "$pkg" > $MARBLE_PENDING/package;
  cp -f $AKHOME/marble-other-manager-packages $MARBLE_PENDING/other-packages 2>/dev/null;
  cat > $MARBLE_HOOK <<'HOOK'
#!/system/bin/sh
# One-shot, written by the Marble kernel zip: install the manager app that
# matches the flashed kernel, remove other KernelSU-family manager apps, finish
# ksud setup, then delete itself. Log: /data/adb/marble-pending.log
P=/data/adb/marble-pending
LOG=/data/adb/marble-pending.log
exec >>"$LOG" 2>&1
echo "== $(date) marble first-boot manager setup"
pkg="$(cat $P/package 2>/dev/null)"
[ -n "$pkg" ] && [ -f "$P/manager.apk" ] || { echo "nothing staged"; rm -f "$0"; exit 0; }
i=0
until [ "$(getprop sys.boot_completed)" = 1 ] && pm path android >/dev/null 2>&1; do
  i=$((i + 1)); [ $i -gt 120 ] && { echo "package manager not ready"; exit 0; }
  sleep 1
done
# Always install the staged build: it is the exact one matching the kernel
# (an already installed older/newer app is replaced, downgrades included).
tmp=/data/local/tmp/marble-manager.apk
cp -f "$P/manager.apk" $tmp && chmod 644 $tmp
out="$(pm install -r -d $tmp 2>&1)"; echo "install: $out"
case "$out" in
  *Success*) ;;
  *)
    # Signature or downgrade refusal: replace the app (its data is disposable;
    # root state lives in /data/adb).
    pm uninstall "$pkg"; out="$(pm install -r $tmp 2>&1)"; echo "reinstall: $out" ;;
esac
rm -f $tmp
case "$out" in
  *Success*) ;;
  *) echo "app install failed; will retry next boot"; exit 0 ;;
esac
for other in $(cat $P/other-packages 2>/dev/null); do
  [ "$other" = "$pkg" ] && continue
  pm path "$other" >/dev/null 2>&1 && pm uninstall --user 0 "$other" && echo "removed $other"
done
# Finish what the app does on first launch (`ksud install`), using the
# installed app's own ksud and adbroot library.
libdir="$(dirname "$(pm path "$pkg" | head -n1 | sed 's/^package://')")/lib/arm64"
if [ -x "$libdir/libksud.so" ]; then
  if [ -f "$libdir/libadbroot.so" ]; then
    "$libdir/libksud.so" install --libadbroot "$libdir/libadbroot.so"
  else
    "$libdir/libksud.so" install
  fi
  echo "ksud install: $?"
fi
rm -rf "$P"
rm -f "$0"
echo "done"
HOOK
  chmod 755 $MARBLE_HOOK;
  chcon u:object_r:adb_data_file:s0 $MARBLE_HOOK 2>/dev/null;
  return 0;
}

# Install the app now (only possible with Android running); remove the other
# manager apps only once it is in place.
marble_install_app_now() {
  pkg="$1";
  [ -f $AKHOME/manager.apk ] && [ "$pkg" ] || return 1;
  pm=/system/bin/pm;
  tmp_apk=/data/local/tmp/marble-manager.apk;
  cp -f $AKHOME/manager.apk $tmp_apk && chmod 644 $tmp_apk;
  out="$($pm install -r -d $tmp_apk 2>&1)";
  case "$out" in
    *Success*) ;;
    *)
      # Signature or downgrade refusal: replace it with the matching build.
      ui_print "  replacing the installed app with the matching build";
      $pm uninstall $pkg >/dev/null 2>&1;
      out="$($pm install -r $tmp_apk 2>&1)";;
  esac;
  rm -f $tmp_apk;
  if ! echo "$out" | grep -q Success || ! $pm path $pkg >/dev/null 2>&1; then
    ui_print "  app install failed now: $(echo "$out" | tail -n 1)";
    return 1;
  fi;
  ui_print "  installed $pkg";
  for other in $(cat $AKHOME/marble-other-manager-packages 2>/dev/null); do
    [ "$other" != "$pkg" ] || continue;
    if $pm path $other >/dev/null 2>&1; then
      # --user 0 also covers a manager bundled as a system app (the ROM's
      # built-in KernelSU-Next); undo with: pm install-existing <package>
      if $pm uninstall --user 0 $other >/dev/null 2>&1; then
        ui_print "  removed other manager app: $other";
      else
        ui_print "  could not remove $other; uninstall it manually";
      fi;
    fi;
  done;
  return 0;
}

# Before anything is written: a root-manager kernel must be able to fix up
# /data/adb (retire another fork's ksud, install its own), or the first boot
# can hang at the logo. Stop here if /data is not accessible.
precheck_manager_data() {
  new_mgr="$(cat $AKHOME/marble-manager 2>/dev/null)";
  [ "$new_mgr" ] && [ "$new_mgr" != none ] || return 0;
  [ -d $MARBLE_ADB ] && return 0;
  if ! mountpoint -q /data 2>/dev/null && mount /data 2>/dev/null; then
    adb_ok="";
    [ -d $MARBLE_ADB ] && adb_ok=1;
    umount /data 2>/dev/null;
    [ "$adb_ok" ] && return 0;
  fi;
  if marble_force_requested; then
    ui_print "WARNING: /data/adb not accessible; continuing (force flash).";
    return 0;
  fi;
  ui_print " ";
  ui_print "STOP: /data/adb is not accessible here, so the";
  ui_print "previous root manager's ksud cannot be replaced";
  ui_print "and the first boot could hang at the logo.";
  ui_print "Flash from Android (e.g. Kernel Flasher) instead.";
  abort "Cannot prepare /data/adb. Nothing was flashed.";
}

setup_manager() {
  new_mgr="$(cat $AKHOME/marble-manager 2>/dev/null)";
  [ "$new_mgr" ] || return 0;
  pkg="$(cat $AKHOME/marble-manager-package 2>/dev/null)";

  mounted_data="";
  if [ ! -d $MARBLE_ADB ] && ! mountpoint -q /data 2>/dev/null; then
    mount /data 2>/dev/null && mounted_data=1;
  fi;
  if [ ! -d $MARBLE_ADB ]; then
    ui_print " ";
    ui_print "Warning: /data/adb is not accessible here.";
    if [ "$new_mgr" != none ]; then
      ui_print "If you are switching root manager (e.g. from the";
      ui_print "ROM's built-in KernelSU-Next to ${new_mgr}), boot can";
      ui_print "hang at the logo. Flash from Android (Kernel Flasher)";
      ui_print "instead, or remove /data/adb/ksud before rebooting.";
    fi;
    [ "$mounted_data" ] && umount /data 2>/dev/null;
    return 0;
  fi;

  marker=$MARBLE_ADB/.marble-manager;
  old_mgr="$(cat $marker 2>/dev/null)";
  # Same manager under its previous name (ReSukiSU is now BakaSU): not a switch.
  [ "$old_mgr" = resukisu ] && old_mgr=bakasu;
  switched="";
  if [ "$old_mgr" != "$new_mgr" ] && { [ -e $MARBLE_ADB/ksud ] || [ -d $MARBLE_ADB/ksu ]; }; then
    switched=1;
    stamp="$(date +%Y%m%d-%H%M%S 2>/dev/null || date +%s)";
    bak=$MARBLE_ADB/marble-backup/${stamp}-from-${old_mgr:-rom-builtin};
    mkdir -p $bak;
    ui_print " ";
    ui_print "Root manager change: ${old_mgr:-ROM built-in} -> ${new_mgr}";
    for f in ksud ksu; do
      [ -e $MARBLE_ADB/$f ] && mv -f $MARBLE_ADB/$f $bak/ && ui_print "  moved /data/adb/$f to backup";
    done;
    if [ "$new_mgr" != none ] && [ -d $MARBLE_ADB/modules ]; then
      for m in $MARBLE_ADB/modules/*/; do
        [ -d "$m" ] || continue;
        if [ ! -e "${m}disable" ]; then
          touch "${m}disable" && basename "$m" >> $bak/disabled-modules.txt;
        fi;
      done;
      [ -s $bak/disabled-modules.txt ] && ui_print "  disabled $(wc -l < $bak/disabled-modules.txt) module(s) for the first boot";
    fi;
    ui_print "  backup: $bak";
  fi;
  echo "$new_mgr" > $marker;

  if [ "$new_mgr" != none ]; then
    ver="$(cat $AKHOME/marble-manager-version 2>/dev/null)";
    # The bundled ksud + app are the exact build of the manager commit this
    # kernel was built from, so they always replace whatever is installed.
    if marble_install_ksud; then
      ui_print "Installed ${new_mgr} ksud ${ver} (matches this kernel)";
      marble_stage_first_boot "$pkg" &&
        ui_print "First boot installs the ${new_mgr} app ${ver} and removes other managers.";
      if marble_android_running && [ -f $AKHOME/manager.apk ]; then
        ui_print "Installing ${new_mgr} manager app ${ver} now...";
        marble_install_app_now "$pkg";
      fi;
    else
      ui_print "No exact ${new_mgr} build bundled: install the ${new_mgr}";
      ui_print "app matching this kernel yourself after boot.";
    fi;
    [ "$switched" ] && [ -s "$bak/disabled-modules.txt" ] &&
      ui_print "Re-enable your modules in the ${new_mgr} app after booting.";
  fi;

  [ "$mounted_data" ] && umount /data 2>/dev/null;
  return 0;
}

ui_print " ";
ui_print "Supported devices: marble, marblein";
ui_print "Current boot image will be backed up before flashing.";

dump_boot;
check_kernel_series;
precheck_manager_data;
backup_current_boot;
write_boot;
setup_manager;
