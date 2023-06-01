#!/bin/bash
set -e
trap '_unmount' EXIT
chroot="${HOME}/gentoo"
PKGDIR="/var/cache/binpkgs"

_unmount() {
        grep "$chroot" /proc/mounts | awk '{print $2}' |
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

get_pkgs(){
        fdver() {
                category=$(dirname "$pkg")
                overlay=$(find /var/db/repos/ -wholename "*${pkg}" | awk -F '/' '{print $5}')
                br0=$(grep "::$overlay" /etc/portage/package.accept_keywords | awk '{print $NF}')
                br1=$(grep -E "${category}/\*|${pkg}" /etc/portage/package.accept_keywords | awk '{print $NF}')
                
                if [ "$br0" = "~amd64" -o "$br1" = "~amd64" ]; then
                        regex="KEYWORDS=.*[~]amd64[^-]"
                else
                        regex="KEYWORDS=.*[^~]amd64[^-]"
                fi

                if [ -z "$br0" -o -z "$br1" ] && grep -q "${pkg}" /etc/portage/package.unmask; then
                        grep -Eo "${pkg}-[0-9].*" /etc/portage/package.unmask

                elif [ "$br0" = "**" -o "$br1" = "**"  ]; then
                        ver=$(printf '%s\n' /var/db/repos/*/"${pkg}"/*9999*.ebuild | grep -o -- "-9999.*.ebuild" | sed "s/\.ebuild//g" | sed "s/^-//g")
                        export ver
                else
                        grep -HEro "$regex" /var/db/repos/*/"${pkg}" |
                        grep -v ".*-9999.*" | grep -Eo ".*.ebuild" | sort -V | tail -1
                fi

        }

        _binpkg() {
                basepkg=$(basename "$pkg")
                xpak=$(ls -1v "${PKGDIR}/${pkg}/${basepkg}"*.xpak 2>/dev/null |
                        tail -1 | grep -Eo -- "-[0-9].*")

                tmp=$(echo "$xpak" | rev | awk -F '-' '{print $1}' | rev)
                [[ -n "$tmp" ]] && echo "$xpak" | sed -e "s/${tmp}//g" -e "s/^-//g" -e "s/-$//g"
        }

        mapfile -t packages < /list

        for pkg in "${packages[@]}"; do
                while read -r ebuild; do
                        [[ -z "$ver" ]] && ver=$(echo "$ebuild" | grep -Eo -- "-[0-9].*" | sed -e "s/\.ebuild//g" -e "s/^-//g")
                        binver=$(_binpkg || true)

                        if [[ "$ver" != "$binver" ]]; then
                                printf "%s\n" "$pkg" >> /pkgs
                        fi
                        unset ver
                done < <(fdver)
        done
        [[ -f /pkgs ]] && awk -i inplace '!seen[$0]++' /pkgs
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
        cd "$HOME" || exit 1
        rm -rf /etc/portage/ /var/db/repos/* "$PKGDIR"
        cp -af "${HOME}/portage" /etc/
        sed -i "s/^J=.*$/J=\"$(nproc --all)\"/" /etc/portage/make.conf
        ln -sf /var/db/repos/gentoo/profiles/default/linux/amd64/17.1/desktop/systemd /etc/portage/make.profile
        curl -sSL -o - https://gitlab.com/thecatvoid/gentoo-bin/-/raw/main/dev-vcs/git/git | tar -C / -pixJf - || true
        git clone --depth=1 --jobs $(nproc --all) --branch main --single-branch \
                "https://gitlab.com/thecatvoid/gentoo-bin.git" "$PKGDIR"

        emerge --sync
        fixpackages
        emaint --fix binhost
        cat "${HOME}/package_list" > /list
        qlist -I >> /list
        awk -i inplace '!seen[$0]++' /list
        get_pkgs

}

build_cmd() {
        if [[ -n "$(cat /pkgs)" ]]; then
                xargs emerge --update --newuse < /pkgs || exit 1
        fi
}

build_binpkgs_cmd() {
        mapfile -t pkgs < /pkgs
        for i in "${pkgs[@]}"; do rm -rf "${PKGDIR}/${i}"; done
        quickpkg --include-config=y --include-unmodified-config=y "${pkgs[@]}"
        fixpackages
        emaint --fix binhost
}

upload() {
        repo="https://gitlab.com/thecatvoid/gentoo-bin.git"
        bin="${chroot}/../binpkgs/"
        sudo rm -rf "$bin"
        sudo cp -axf "${chroot}${PKGDIR}" "$bin"
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

        cd "$bin" || exit 1
        rm -rf .git
        cp -a $(printf "%s\n" dev-vcs/git/* | sort -V | tail -1) dev-vcs/git/git 
        git init -b main
        git remote add origin "$repo"
        git add -A
        git commit -m 'commit'
        git push --set-upstream "https://oauth2:${GIT_TOKEN}@gitlab.com/thecatvoid/gentoo-bin.git" main -f 2>&1 |
                sed "s/$GIT_TOKEN/token/g"

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
