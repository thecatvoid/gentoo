#!/bin/bash
# A script to only install packages which dont have same version as installed or which arent installed

# Don't declare arr on every loop
arr=()
# Read package names such as foo/bar from ./package_list
while read -r list
        # Find ebuild files and get package versions from it
do
        find /var/db/repos/ -type f -name '*.ebuild' | grep -o ".*${list}.*" | sort -n | grep -v '9999' | tail -1 | while read -r temp
do 
        ver=$(echo "$temp" | grep -Eo -- "-[0-9].*" | sed -e 's/.ebuild//g' -e 's/^-//g')
        
        # Check if package is same package ver installed or even the package if not add those names to array
        qlist -Iv | grep -o "${list}.*" | while read -r installed
do
        if [[ "${list}-${ver}" != "${installed}" ]]
        then
                # Add elements to arr
                export arr+=("$list") 
                echo "${arr[@]}"
        fi

done
done
done < ./package_list
echo "${arr[@]}"
