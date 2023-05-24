#!/bin/bash
set -e
trap '_unmount' EXIT
chroot="${HOME}/gentoo"

_unmount() {
        grep "$HOME/gentoo" /proc/mounts | awk '{print $3}' |
                xargs -I{} sudo umount -Rf {} > /dev/null 2>&1 || true
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
        printf '%s\n' 'en_US.UTF-8 UTF-8' > /etc/locale.gen
        printf '%s\n' 'LANG=en_US.UTF-8' 'LC_ALL=en_US.UTF-8' 'LANGUAGE=en' > /etc/locale.conf
        locale-gen
        cd "$HOME" || exit
        rm -rf /etc/portage/
        emerge-webrsync
        cp -af "${HOME}/portage" /etc/
        sed -i "s/^J=.*/J=\"$(nproc --all)\"/" /etc/portage/make.conf
        ln -sf /var/db/repos/gentoo/profiles/default/linux/amd64/17.1/desktop/systemd /etc/portage/make.profile
        emerge dev-vcs/git app-accessibility/at-spi2-core
        rm -rf /var/db/repos/*
        emerge --sync
        cp -f "${HOME}/package_list" /list
}

build_cmd() {
        pkgs=()
        while read -r pkg
        do pkgs+=("$pkg")
        done < /list

        emerge "${pkgs[@]}" || exit 1
}

build_binpkgs_cmd() {
        rm -rf /var/cache/binpkgs/*
        curl -sS "https://raw.githubusercontent.com/thecatvoid/gentoo-bin/main/Packages" \
                -o /var/cache/binpkgs/Packages

        quickpkg --include-config=y "*/*"

        fixpackages
        emaint --fix binhost
}

upload() {
        repo="https://gitlab.com/thecatvoid/gentoo-bin.git"
        bin="${HOME}/binpkgs"
        mkdir -p "$bin"
        cd "$bin" || exit
        sudo cp -af "$HOME"/gentoo/var/cache/binpkgs/* ./
        sudo chown -R "${USER}:${USER}" "$bin"
        
        git config --global user.email "voidcat@tutanota.com"
        git config --global user.name "thecatvoid"
        
        curl --header "Authorization: Bearer $GIT_TOKEN" \
        --request DELETE "https://gitlab.com/api/v4/projects/thecatvoid%2Fgentoo-bin" > /dev/null 2>&1
        
        sleep 10
        
        curl --header "Content-Type: application/json" \
        --header "Authorization: Bearer $GIT_TOKEN" \
        --data '{"name": "gentoo-bin", "visibility": "public"}' \
        --request POST "https://gitlab.com/api/v4/projects" > /dev/null 2>&1
        
        git init -b main
        git remote add origin "$repo"
        git add -A
        git commit -m 'commit'
        git push --set-upstream "https://oauth2:${GIT_TOKEN}@gitlab.com/thecatvoid/gentoo-bin.git" main -f 2>&1 |
                sed "s/$GIT_TOKEN/token/"
       
 }

# We got to do exec function inside gentoo chroot not on runner
setup_build() {
        rootch setup_build_cmd
}

build() {
        rootch build_cmd
}

build_binpkgs() {
        rootch build_binpkgs_cmd
}

# Exec functions when called as args
for cmd; do $cmd; done
