# This file is a part of the Armbian build script
# https://github.com/armbian/build/

# Functions:
# build_media_packages

# build_media_packages
#
build_media_packages()
{
	local built_ok=()
	local failed=()

	if [[ $IMAGE_TYPE == user-built ]]; then
		# if user-built image compile only for selected family/release
		target_media_family="$MEDIA_FAMILY"
		target_release="$RELEASE"
	else
		# only make packages for recent releases. There are no changes on older
		target_media_family=$( ls $SRC/packages/media-pkgs/ )
		target_release="stretch bionic buster bullseye eoan focal"
	fi

	for media_family in $target_media_family; do
		source $SRC/packages/media-pkgs/$media_family/family.conf
		local arch=$FAMILY_ARCH
		
		for release in $target_release; do
			display_alert "Starting media package building process" "$media_family/$release" "info"

			# prepare chroot
			local target_dir=$SRC/cache/mediapkg/${media_family}-${release}-v${CHROOT_CACHE_VERSION}
			[[ ! -f $target_dir/root/.debootstrap-complete ]] && create_chroot "$target_dir" "$release" "$arch"
			[[ ! -f $target_dir/root/.debootstrap-complete ]] && exit_with_error "Creating chroot failed" "$media_family/$release"
			local t=$target_dir/root/.update-timestamp
			if [[ ! -f $t || $(( ($(date +%s) - $(<$t)) / 86400 )) -gt 7 ]]; then
				display_alert "Upgrading packages" "$media_family/$release" "info"
				systemd-nspawn -a -q -D $target_dir /bin/bash -c "apt -q update; apt -q -y upgrade; apt clean"
				date +%s > $t
			fi
			mkdir -p $target_dir/root/build
			mkdir -p $target_dir/root/media-build/source
			mkdir -p $target_dir/root/media-build/packages
			rm -rf $target_dir/root/media-build/packages/*

			# copy the corresponding media-family dir into the chroot
			display_alert "Copying sources"
			rsync -aq $SRC/packages/media-pkgs/$media_family $target_dir/media-build/source/

			# create wrapper script to run the buildscripts
			cat <<-EOF > $target_dir/root/build-media.sh
			#!/bin/bash
			export HOME="/root"
			export DEBIAN_FRONTEND="noninteractive"
			export DEB_BUILD_OPTIONS="nocheck noautodbgsym"
			export CCACHE_TEMPDIR="/tmp"
			export DEBFULLNAME="$MAINTAINER"
			export DEBEMAIL="$MAINTAINERMAIL"
			$(declare -f display_alert)
			cd /root/media-build/source/scripts
			source \$1
			if [[ \$? -eq 0 ]]; then
				display_alert "Done building" "$package_name $release/$arch" "ext"
				exit 0
			else
				display_alert "Failed building" "$package_name $release/$arch" "err"
				exit 2
			fi
			EOF
			
			chmod +x $target_dir/root/build-media.sh

			# run scripts within the chroot
			for pkg-script in $target_dir/root/media-build/source/scripts/*.sh; do
				eval systemd-nspawn -a -q --capability=CAP_MKNOD -D $target_dir --tmpfs=/root/build --tmpfs=/tmp:mode=777 /bin/bash -c "/root/build-media.sh $pkg-script"  2>&1 \
					${PROGRESS_LOG_TO_FILE:+' | tee -a $DEST/debug/buildpkg.log'}
				if [[ ${PIPESTATUS[0]} -eq 2 ]]; then
					failed+=("$pkg-script:$media_family/$release")
				else
					built_ok+=("$pkg-script:$media_family/$release")
				fi
			done
			
			# copy resulting packages to destination
			cp $target_dir/root/media-build/packages/*.deb $DEST/debs/media/ 
			
		done
	done
	if [[ ${#built_ok[@]} -gt 0 ]]; then
		display_alert "Following package scripts were run without errors" "" "info"
		for p in ${built_ok[@]}; do
			display_alert "$p"
		done
	fi
	if [[ ${#failed[@]} -gt 0 ]]; then
		display_alert "Following packages failed to build" "" "wrn"
		for p in ${failed[@]}; do
			display_alert "$p"
		done
	fi
} #############################################################################
