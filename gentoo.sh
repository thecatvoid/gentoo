#!/bin/bash
set -e

setup_chroot() {
        wget -qnv "${url}${file}" -O "/var/tmp/${file}"
        mkdir "$chroot"
        sudo tar -C "${chroot}" -xpf "/var/tmp/${file}" --xattrs-include='*.*' --numeric-owner 2>/dev/null
}

setup_build_cmd() {
        cd "$HOME" || exit
        source /etc/profile
        rm -rf /etc/portage/
        emerge-webrsync
        cp -af "${HOME}/portage" /etc/
        ln -sf /var/db/repos/gentoo/profiles/default/linux/amd64/17.1/desktop/systemd/ /etc/portage/make.profile
        emerge dev-vcs/git sys-kernel/gentoo-sources
        rm -rf /var/db/repos/* 
        emerge --sync
        list="${HOME}/package_list"
        qlist -I >> "$list"
        awk -i inplace '!seen[$0]++' "$list"
        while read -r pkg; do pkgs+=("$pkg"); done < "$list"
        unmount
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
        binpkg="$(echo "$pkg" | xargs -n1 | sort -n | tail -1)"
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
}

build() {
        rootch build_cmd
}

buildpkgs() {
        rootch buildpkgs_cmd
}

# Exec functions when called as args
for cmd; do source ./env && $cmd; done
