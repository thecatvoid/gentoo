#!/bin/bash
set -e
chroot="${HOME}/gentoo"
trap 'sudo umount -Rf "${chroot}"/* > /dev/null 2>&1 || true' EXIT

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

bashin() {
        rootch /bin/bash
}

setup_chroot() {
        url="https://gentoo.osuosl.org/releases/amd64/autobuilds/current-stage3-amd64-desktop-systemd/"
        file="$(curl -s "$url" | grep -Eo 'href=".*"' | awk -F '>' '{print $1}' |
                sed -e 's/href=//g' -e 's/"//g' | grep -o "stage3-amd64-desktop-systemd-$(date +%Y).*.tar.xz" | uniq)"

        curl -sSL "${url}${file}" -o "/var/tmp/${file}"
        mkdir "$chroot"
        sudo tar -C "${chroot}" -xpf "/var/tmp/${file}" --xattrs-include='*.*' --numeric-owner 2>/dev/null
}

setup_build_cmd() {
        cd "$HOME" || exit
        rm -rf /etc/portage/
        emerge-webrsync
        cp -af "${HOME}/portage" /etc/
        sed -i "s/^J=.*/J=\"$(nproc --all)\"/" /etc/portage/make.conf
        ln -sf /var/db/repos/gentoo/profiles/default/linux/amd64/17.1/desktop/systemd /etc/portage/make.profile
        emerge dev-vcs/git app-accessibility/at-spi2-core
        rm -rf /var/db/repos/* 
        emerge --sync
}

build_cmd() {
        list="${HOME}/package_list"
        pkgs=()
        while read -r pkg; do pkgs+=("$pkg"); done < "$list"
        emerge "${pkgs[@]}" || exit 1
}

buildpkgs_cmd() {
        rm -rf /var/cache/binpkgs/*
        curl -sS "https://raw.githubusercontent.com/thecatvoid/gentoo-bin/main/Packages" \
                -o /var/cache/binpkgs/Packages

        qlist -I | grep -Ev -- 'acct-user/.*|acct-group/.*|virtual/.*|sys-kernel/.*-sources|.*/.*-bin' |
                xargs quickpkg --include-config=y

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
}

build() {
        rootch build_cmd
}

buildpkgs() {
        rootch buildpkgs_cmd
}

# Exec functions when called as args
for cmd; do $cmd; done
