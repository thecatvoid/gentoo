#!/bin/bash
set -e

chroot="${HOME}/gentoo"

unmount() {
	for i in dev proc sys tmp run
	do
		sudo umount -Rf "${chroot}/${i}" > /dev/null 2>&1 || true
	done
}

rootch() {
	sudo mount --rbind /dev "${chroot}/dev"
	sudo mount --make-rslave "${chroot}/dev"
	sudo mount -t proc /proc "${chroot}/proc"
	sudo mount --rbind /sys "${chroot}/sys"
	sudo mount --make-rslave "${chroot}/sys"
	sudo mount --rbind /tmp "${chroot}/tmp"
	sudo mount --bind /run "${chroot}/run"
	sudo cp -L /etc/resolv.conf "${chroot}/etc/"
	sudo cp -a ./* "${chroot}/root/"
	sudo chroot "${chroot}" /root/gentoo.sh "$@"
}

setup_chroot() {
        url="https://gentoo.osuosl.org/releases/amd64/autobuilds/current-stage3-amd64-desktop-systemd/"
        file="$(curl -s "$url" | grep -Eo 'href=".*"' | awk -F '>' '{print $1}' |
                sed 's/href=//g' | sed 's/"//g' |
                grep -Eo "stage3-amd64-desktop-systemd-$(date +%Y).*.tar.xz" | uniq)"
        wget -qnv "${url}${file}" -O "/var/tmp/${file}"
        mkdir "$chroot"
        sudo tar -C "${chroot}" -xpf "/var/tmp/${file}" --xattrs-include='*.*' --numeric-owner 2>/dev/null
}

setup_build_cmd() {
        cd "$HOME" || exit
        rm -rf /etc/portage/
        emerge-webrsync
        cp -af "${HOME}/portage" /etc/
        sed -i "s/MAKEOPTS=.*/MAKEOPTS=\"$(nproc --all)\"/g" /etc/portage/make.conf
        ln -sf /var/db/repos/gentoo/profiles/default/linux/amd64/17.1/desktop/systemd/ /etc/portage/make.profile
        emerge dev-vcs/git sys-kernel/gentoo-sources
        rm -rf /var/db/repos/* 
        emerge --sync
        list="${HOME}/package_list"
        qlist -I >> "$list"
        awk -i inplace '!seen[$0]++' "$list"
        while read -r pkg; do pkgs+=("$pkg"); done < "$list"
}

build_cmd() {
        emerge "${pkgs[@]}" || exit 1
}

buildpkgs_cmd() {
        rm -rf /var/cache/binpkgs
        git clone --depth=1 https://github.com/thecatvoid/gentoo-bin /var/cache/binpkgs
        rm -rf /var/cache/binpkgs/.git
        qlist -I | grep -Ev -- 'acct-user/.*|acct-group/.*|virtual/.*|sys-kernel/.*-sources|.*/.*-bin' |
                xargs quickpkg --include-config=y

        echo /var/cache/binpkgs/*/* | xargs -n1 | while read -r list; do
        pkg="$(echo ${list}/*.xpak)"
        echo "$pkg" | grep -q ' ' || continue
        binpkg="$(echo "$pkg" | xargs -n1 | grep -o '.*-1.xpak' | sort -n | tail -1)"
        oldbinpkgs=()
        for i in $(echo "$pkg" | sed "s#$binpkg##"); do oldbinpkgs+=("$i"); done
        rm "${oldbinpkgs[@]}"; done
        fixpackages
        emaint --fix binhost
}

upload() {
        bin="${HOME}/binpkgs"
        sudo cp -af "${HOME}/gentoo/var/cache/binpkgs/" "$bin"
        sudo chown -R "${USER}:${USER}" "$bin"
        cd "$bin" || exit
        git config --global user.email "voidcat@tutanota.com"
        git config --global user.name "thecatvoid"
        git init -b main
        git add -A
        git commit -m 'commit'
        git push --set-upstream "https://oauth2:${GITHUB_TOKEN}@github.com/thecatvoid/gentoo-bin" main -f 2>&1 |
                sed "s/$GITHUB_TOKEN/token/"
}

# We got to do exec function inside gentoo chroot not on runner
setup_build() {
        rootch setup_build_cmd
        unmount
}

build() {
        rootch build_cmd
        unmount
}

buildpkgs() {
        rootch buildpkgs_cmd
        unmount
}

# Exec functions when called as args
for cmd; do $cmd; done
