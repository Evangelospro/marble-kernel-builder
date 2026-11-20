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

# Print "X.Y" from the first "Linux version X.Y.Z" banner in a raw kernel image.
kernel_major_minor() {
  [ -f "$1" ] || return 0;
  strings "$1" 2>/dev/null | sed -n 's/^.*Linux version \([0-9][0-9]*\.[0-9][0-9]*\)[.-].*$/\1/p' | head -n 1;
}

# Refuse to flash an Image whose kernel series differs from the ROM's kernel
# (e.g. a 5.10 Image on an Evolution X 6.6 build). The ROM's vendor_dlkm,
# vendor_boot and system_dlkm modules are built for its own kernel, so a
# mismatched Image cannot load them and the phone bootloops.
check_kernel_series() {
  new_ver="$(kernel_major_minor "$AKHOME/Image")";
  cur_ver="";
  for k in $SPLITIMG/kernel; do
    cur_ver="$(kernel_major_minor "$k")";
    [ "$cur_ver" ] && break;
  done;
  cur_src="boot image";
  if [ -z "$cur_ver" ]; then
    cur_ver="$(uname -r 2>/dev/null | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')";
    cur_src="running kernel";
  fi;

  ui_print " ";
  ui_print "New kernel     : ${new_ver:-unknown}";
  ui_print "Current kernel : ${cur_ver:-unknown} (${cur_src})";
  if [ -z "$new_ver" ] || [ -z "$cur_ver" ]; then
    ui_print "Warning: could not compare kernel versions.";
    ui_print "Make sure this zip matches your ROM's kernel version!";
    return 0;
  fi;
  if [ "$new_ver" != "$cur_ver" ]; then
    # Escape hatch, e.g. recovering a slot that already holds a wrong-series
    # kernel: rename the zip to end in "-force.zip" or create
    # /tmp/.marble-force-flash before flashing.
    case "$(basename "${ZIPFILE:-x.zip}" .zip)" in
      *-force) force_flash=1;;
    esac;
    [ -f /tmp/.marble-force-flash ] && force_flash=1;
    if [ "$force_flash" ]; then
      ui_print "Kernel version mismatch (${new_ver} vs ${cur_ver}) ignored: force flash requested.";
      return 0;
    fi;
    ui_print " ";
    ui_print "This zip has a ${new_ver} kernel, but your ROM";
    ui_print "runs a ${cur_ver} kernel. Its modules can't load";
    ui_print "on ${new_ver}, so flashing would bootloop.";
    ui_print "Build from the kernel branch your ROM uses";
    ui_print "(e.g. Evolution X 6.6 = evolution-x, default branch).";
    ui_print "If the boot slot already holds a wrong kernel,";
    ui_print "rename this zip to end in -force.zip to override.";
    abort "Kernel version mismatch. Nothing was flashed.";
  fi;
}

# KernelSU-family kernels inject a *blocking* init step:
#   on post-fs-data: exec ... -- /data/adb/ksud post-fs-data
# If /data/adb/ksud belongs to a different fork (e.g. the ROM's built-in
# KernelSU-Next while this zip carries ReSukiSU), it can hang boot at the logo.
# When the root manager changes, move the old userspace aside (backup kept) and
# disable modules for the first boot. With no ksud the exec fails instantly and
# boot continues; opening the new manager app installs its own ksud.
prepare_manager_userspace() {
  new_mgr="$(cat $AKHOME/marble-manager 2>/dev/null)";
  [ "$new_mgr" ] || return 0;

  adb_dir=/data/adb;
  mounted_data="";
  if [ ! -d $adb_dir ] && ! mountpoint -q /data 2>/dev/null; then
    mount /data 2>/dev/null && mounted_data=1;
  fi;
  if [ ! -d $adb_dir ]; then
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

  marker=$adb_dir/.marble-manager;
  old_mgr="$(cat $marker 2>/dev/null)";
  if [ "$old_mgr" != "$new_mgr" ] && { [ -e $adb_dir/ksud ] || [ -d $adb_dir/ksu ]; }; then
    stamp="$(date +%Y%m%d-%H%M%S 2>/dev/null || date +%s)";
    bak=$adb_dir/marble-backup/${stamp}-from-${old_mgr:-rom-builtin};
    mkdir -p $bak;
    ui_print " ";
    ui_print "Root manager change: ${old_mgr:-ROM built-in} -> ${new_mgr}";
    for f in ksud ksu; do
      [ -e $adb_dir/$f ] && mv -f $adb_dir/$f $bak/ && ui_print "  moved /data/adb/$f to backup";
    done;
    if [ "$new_mgr" != none ] && [ -d $adb_dir/modules ]; then
      for m in $adb_dir/modules/*/; do
        [ -d "$m" ] || continue;
        if [ ! -e "${m}disable" ]; then
          touch "${m}disable" && basename "$m" >> $bak/disabled-modules.txt;
        fi;
      done;
      [ -s $bak/disabled-modules.txt ] && ui_print "  disabled $(wc -l < $bak/disabled-modules.txt) module(s) for the first boot";
    fi;
    ui_print "  backup: $bak";
    if [ "$new_mgr" != none ]; then
      ui_print "After boot, open the ${new_mgr} manager app once";
      ui_print "to install its ksud, then re-enable modules.";
    fi;
  fi;
  echo "$new_mgr" > $marker;
  [ "$mounted_data" ] && umount /data 2>/dev/null;
  return 0;
}

# Install this kernel's official manager app and remove other KernelSU-family
# manager apps (they can't manage this kernel and confuse multi-manager
# detection). Needs a running Android (Kernel Flasher etc.): recovery has no
# package manager, so there the APK is only copied next to the boot backup.
manage_manager_apps() {
  new_mgr="$(cat $AKHOME/marble-manager 2>/dev/null)";
  [ "$new_mgr" ] && [ "$new_mgr" != none ] || return 0;
  apk=$AKHOME/manager.apk;
  pkg="$(cat $AKHOME/marble-manager-package 2>/dev/null)";

  if ! ps -A 2>/dev/null | grep -q '[z]ygote' && ! ps 2>/dev/null | grep -q '[z]ygote'; then
    ui_print " ";
    if [ -f "$apk" ] && [ -d /sdcard/marble-kernel-backup ]; then
      cp -f $apk /sdcard/marble-kernel-backup/${new_mgr}-manager.apk 2>/dev/null &&
        ui_print "Manager app saved: /sdcard/marble-kernel-backup/${new_mgr}-manager.apk";
    fi;
    ui_print "Flashed from recovery: install the ${new_mgr} app and";
    ui_print "uninstall other KernelSU managers after booting.";
    return 0;
  fi;

  pm=/system/bin/pm;
  installed=0;
  if [ -f "$apk" ] && [ "$pkg" ]; then
    ui_print " ";
    ui_print "Installing ${new_mgr} manager app (${pkg})...";
    tmp_apk=/data/local/tmp/marble-${new_mgr}-manager.apk;
    cp -f $apk $tmp_apk && chmod 644 $tmp_apk;
    out="$($pm install -r $tmp_apk 2>&1)";
    case "$out" in
      *INSTALL_FAILED_UPDATE_INCOMPATIBLE*|*signatures\ do\ not\ match*)
        # Same package installed with another signing key (e.g. a fork build):
        # it can't be updated in place, so replace it.
        ui_print "  existing app has a different signature; replacing it";
        $pm uninstall $pkg >/dev/null 2>&1;
        out="$($pm install -r $tmp_apk 2>&1)";;
    esac;
    rm -f $tmp_apk;
    if $pm path $pkg >/dev/null 2>&1 && echo "$out" | grep -q Success; then
      installed=1;
      ui_print "  installed";
    else
      ui_print "  install failed: $(echo "$out" | tail -n 1)";
      ui_print "  install the ${new_mgr} app manually.";
    fi;
  elif [ "$pkg" ] && $pm path $pkg >/dev/null 2>&1; then
    installed=1;
  else
    ui_print " ";
    ui_print "No manager app bundled: install the ${new_mgr} app manually.";
  fi;

  # Only remove the old managers once the new one is in place.
  [ "$installed" = 1 ] || return 0;
  for other in $(cat $AKHOME/marble-other-manager-packages 2>/dev/null); do
    [ "$other" != "$pkg" ] || continue;
    if $pm path $other >/dev/null 2>&1; then
      # --user 0 also works for a manager bundled as a system app (the ROM's
      # built-in KernelSU-Next); restore with: pm install-existing <package>
      if $pm uninstall --user 0 $other >/dev/null 2>&1; then
        ui_print "Removed other manager app: $other";
      else
        ui_print "Could not remove $other; uninstall it manually.";
      fi;
    fi;
  done;
  return 0;
}

ui_print " ";
ui_print "Supported devices: marble, marblein";
ui_print "Current boot image will be backed up before flashing.";

dump_boot;
check_kernel_series;
backup_current_boot;
write_boot;
prepare_manager_userspace;
manage_manager_apps;
