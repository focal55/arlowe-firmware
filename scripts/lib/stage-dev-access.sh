#!/usr/bin/env bash
# scripts/lib/stage-dev-access.sh
#
# Stage a dev login onto a flashed card's boot partition: userconf.txt (account +
# crypt hash) and authorized_keys (public key). arlowe-userconf consumes both on first
# boot, and only while the unit is unpaired.
#
# Source this file; it defines functions only.

# validate_dev_pubkey <file>: prints the reason and returns 1 unless <file> is a
# public key. A private key is refused by name because pasting the wrong half of the
# pair is the likely mistake, and it would then sit on a FAT partition.
validate_dev_pubkey() {
    local file="$1"
    [[ -f "${file}" ]] || { printf 'pubkey file not found: %s\n' "${file}" >&2; return 1; }
    if grep -q 'PRIVATE KEY' "${file}"; then
        printf '%s is a private key; pass the .pub file\n' "${file}" >&2
        return 1
    fi
    case "$(head -n1 "${file}")" in
        ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *|sk-*\ *) ;;
        *) printf '%s is not an SSH public key\n' "${file}" >&2; return 1 ;;
    esac
}

# stage_dev_access <boot_dir> <user> <crypt_hash> <pubkey_file>
stage_dev_access() {
    local boot_dir="$1" user="$2" hash="$3" pubkey="$4"
    validate_dev_pubkey "${pubkey}" || return 1
    if [[ -z "${user}" || "${user}" == *:* ]]; then
        printf 'invalid dev-access user: %s\n' "${user}" >&2
        return 1
    fi
    if [[ "${hash}" != \$* ]]; then
        echo "password hash is not a crypt hash (expected \$6\$...)" >&2
        return 1
    fi
    printf '%s:%s\n' "${user}" "${hash}" > "${boot_dir}/userconf.txt"
    cp "${pubkey}" "${boot_dir}/authorized_keys"
}
