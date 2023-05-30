#!/bin/bash
set -e
trap '_unmount' EXIT
chroot="${HOME}/gentoo"

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
        declare -ag pkgs
        bindir="/var/cache/binpkgs"
        basepkg=$(basename "$pkg")
        fdver() {
                category=$(basename "$pkg")
                overlay=$(find /var/db/repos/ -wholename "*${pkg}" | awk -F '/' '{print $5}')
                branch0=$(grep "::$overlay" /etc/portage/package.accept_keywords | awk '{print $NF}')
                branch1=$(grep "${pkg}" /etc/portage/package.accept_keywords | awk '{print $NF}')
                branch2=$(grep "${category}/\*" /etc/portage/package.accept_keywords | awk '{print $NF}')

                case amd64 in
                        "$branch0"|"$branch1"|"$branch2") regex="KEYWORDS=.*[~]amd64[^-]" ;;
                        *) regex="KEYWORDS=.*[^~]amd64[^-]"
                esac

                if grep -q "${pkg}" /etc/portage/package.unmask; then
                        grep -Eo "${pkg}-[0-9].*" /etc/portage/package.unmask
                else
                        grep -HEro "$regex" /var/db/repos/*/"${pkg}" | sort -V |
                                grep -v ".*-9999.*" | tail -1 | grep -Eo ".*.ebuild"
                fi
        }

        _bindir() {
                xpak=$(ls -1v "${bindir}/${pkg}/${basepkg}"*.xpak 2>/dev/null |
                        tail -1 | grep -Eo -- "-[0-9].*")

                tmp=$(echo "$xpak" | rev | awk -F '-' '{print $1}' | rev)
                echo "$xpak" | sed "s/-${tmp}//g"
        }

        mapfile -t packages < /list

        for pkg in "${packages[@]}"; do
                while read -r ebuild; do
                        ver=$(echo "$ebuild" | grep -Eo -- "-[0-9].*" | sed "s/\.ebuild//g")
                        pkgv="${pkg}${ver}"
                        binver=$(_bindir || true)
                        xpakv="${pkg}${binver}"

                        if [[ "${pkgv}" != "${xpakv}" ]]; then
                                pkgs+=("$pkg")
                        fi
                done < <(fdver)
        done
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
        ln -sf /usr/src/linux /usr/src/linux-"$(uname -r)"
        cd "$HOME" || exit
        rm -rf /etc/portage/
        emerge-webrsync
        cp -af "${HOME}/portage" /etc/
        sed -i "s/^J=.*$/J=\"$(nproc --all)\"/" /etc/portage/make.conf
        ln -sf /var/db/repos/gentoo/profiles/default/linux/amd64/17.1/desktop/systemd /etc/portage/make.profile
        source /etc/profile && env-update --no-ldconfig
        emerge dev-vcs/git app-accessibility/at-spi2-core
        rm -rf /var/db/repos/* /var/cache/binpkgs/
        git clone --depth=1 "https://gitlab.com/thecatvoid/gentoo-bin.git" /var/cache/binpkgs
        emerge --sync
        fixpackages
        emaint --fix binhost
        cat "${HOME}/package_list" > /list
        qlist -I >> /list
        awk -i inplace '!seen[$0]++' /list
}

build_cmd() {
        source /etc/profile && env-update --no-ldconfig
        declare -ag pkgs
        get_pkgs
        if [[ -n "${pkgs[@]}" ]]; then
        emerge "${pkgs[@]}" || exit 1
        printf "%s\n" "${pkgs[@]}" > /installed
        for i in ${pkgs[@]}; do rm -rf /var/cache/binpkgs/$i; done
        fi
}

build_binpkgs_cmd() {
        mapfile -t installed < /installed
        quickpkg --include-config=y --include-unmodified-config=y "${installed[@]}"
        fixpackages
        emaint --fix binhost
}

upload() {
        repo="https://gitlab.com/thecatvoid/gentoo-bin.git"
        bin="${HOME}/binpkgs/"
        mkdir -p "$bin"
        sudo cp -af "$HOME"/gentoo/var/cache/binpkgs/* "$bin"
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
