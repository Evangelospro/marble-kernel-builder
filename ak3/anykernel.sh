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
    ui_print "Build the source preset that matches your ROM";
    ui_print "(e.g. evolution-x-6.6 for Evolution X 6.6).";
    ui_print "If the boot slot already holds a wrong kernel,";
    ui_print "rename this zip to end in -force.zip to override.";
    abort "Kernel version mismatch. Nothing was flashed.";
  fi;
}

ui_print " ";
ui_print "Supported devices: marble, marblein";
ui_print "Current boot image will be backed up before flashing.";

dump_boot;
check_kernel_series;
backup_current_boot;
write_boot;
