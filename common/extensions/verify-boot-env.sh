# @description Hard-fails an image build when the boot environment that was just written into the image cannot resolve its own root device or its own DTB. At the `image_specific_armbian_env_ready` hook -- after the core has appended `rootdev=`/`rootfstype=` to `armbianEnv.txt` and compiled `boot.scr` -- it compares `rootdev=UUID=` against the real filesystem UUID of the root partition, and checks that `fdtfile=` names a file that actually exists under the image's `/boot`. Opt-in: `ENABLE_EXTENSIONS=verify-boot-env`.

function image_specific_armbian_env_ready__100_verify_rootdev() {
	declare -r env_file="${SDCARD}/boot/armbianEnv.txt"
	[[ -f "${env_file}" ]] || return 0 # The core only calls us when it exists; belt and braces.

	if [[ "${CRYPTROOT_ENABLE:-no}" == "yes" ]]; then
		display_alert "Extension: ${EXTENSION}: skipping rootdev check, cryptroot owns it" "${env_file}" "info"
		return 0
	fi

	declare declared_rootdev
	declared_rootdev="$(sed -n 's/^rootdev=//p' "${env_file}" | tail -n 1)"
	if [[ -z "${declared_rootdev}" ]]; then
		exit_with_error "Extension: ${EXTENSION}: armbianEnv.txt has no rootdev= line, the board falls back to guessing" "${env_file}"
	fi

	# Anything other than a UUID= reference (a raw /dev/mmcblkNpM path, a LABEL=) is exactly the
	# class of value that silently points at the wrong device, but there is nothing here to
	# cross-check it against, so surface it and let the caller decide.
	if [[ "${declared_rootdev}" != UUID=* ]]; then
		display_alert "Extension: ${EXTENSION}: rootdev is not a UUID, cannot cross-check" "${declared_rootdev}" "wrn"
		return 0
	fi

	# The core exports `rootdevice` as a `local` of the very function that fires this hook, so
	# bash's dynamic scoping makes it visible here; it is the image's own loopback partition.
	# `findmnt` is deliberately NOT used as a fallback: while the image is being built it resolves
	# to the *host* filesystem that happens to hold ${SDCARD}, whose UUID has nothing to do with
	# the image's -- comparing against it would fail builds that are perfectly good.
	declare root_dev="${rootdevice:-}"
	if [[ ! -b "${root_dev}" && -n "${LOOP:-}" && -n "${rootpart:-}" && -b "${LOOP}p${rootpart}" ]]; then
		root_dev="${LOOP}p${rootpart}"
	fi
	if [[ ! -b "${root_dev}" ]]; then
		exit_with_error "Extension: ${EXTENSION}: no image block device to verify rootdev against" "rootdevice='${rootdevice:-}' LOOP='${LOOP:-}' rootpart='${rootpart:-}'"
	fi

	declare -r real_rootdev="UUID=$(blkid -s UUID -o value "${root_dev}")"
	if [[ "${real_rootdev}" != "${declared_rootdev}" ]]; then
		exit_with_error "Extension: ${EXTENSION}: armbianEnv.txt rootdev does not match the root filesystem UUID" "armbianEnv '${declared_rootdev}' vs ${root_dev} '${real_rootdev}'"
	fi

	display_alert "Extension: ${EXTENSION}: rootdev matches root filesystem" "${root_dev} ${real_rootdev}" "info"
}

function image_specific_armbian_env_ready__200_verify_fdtfile() {
	declare -r env_file="${SDCARD}/boot/armbianEnv.txt"
	[[ -f "${env_file}" ]] || return 0

	declare fdtfile
	fdtfile="$(sed -n 's/^fdtfile=//p' "${env_file}" | tail -n 1)"
	[[ -n "${fdtfile}" ]] || return 0 # Board does not pick its DTB out of armbianEnv.txt.

	# boot.cmd loads "${prefix}dtb/${fdtfile}"; single-partition images keep /boot inside the rootfs.
	declare candidate
	for candidate in "${SDCARD}/boot/dtb/${fdtfile}" "${SDCARD}/boot/${fdtfile}"; do
		if [[ -f "${candidate}" ]]; then
			display_alert "Extension: ${EXTENSION}: fdtfile exists" "${fdtfile}" "info"
			return 0
		fi
	done

	display_alert "Extension: ${EXTENSION}: what /boot/dtb actually holds" "$(ls -1 "${SDCARD}/boot/dtb" 2>/dev/null | head -20)" "wrn"
	exit_with_error "Extension: ${EXTENSION}: armbianEnv.txt fdtfile names a DTB that is not in the image" "fdtfile='${fdtfile}'"
}
