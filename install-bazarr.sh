#!/usr/bin/env bash
### Description: bazarr installer for Debian/Ubuntu
### Downloads the latest stable release from GitHub and installs it in a Python venv.
### Originally written for Radarr by: DoctorArr - doctorarr@the-rowlands.co.uk on 2021-10-01 v1.0
### Updates for servarr suite made by Bakerboy448, DoctorArr, brightghost, aeramor and VP-EN
### Updates for bazarr made by GiovanniMet

### Boilerplate Warning
#THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
#EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
#MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
#NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
#LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
#OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
#WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

set -Eeuo pipefail
IFS=$'\n\t'

scriptversion="1.0.0"
scriptdate="2026-08-16"

app="bazarr"
app_title="bazarr"
app_port="6767"
install_dir="/opt/bazarr"
data_dir="/var/lib/bazarr"
service_file="/etc/systemd/system/bazarr.service"
venv_dir="${install_dir}/.venv"
release_api="https://api.github.com/repos/morpheus65535/bazarr/releases/latest"
release_asset_url="https://github.com/morpheus65535/bazarr/releases/latest/download/bazarr.zip"
app_umask="0002"

tmp_dir=""
old_install_dir=""

cleanup() {
    if [[ -n "${tmp_dir}" && -d "${tmp_dir}" ]]; then
        rm -rf -- "${tmp_dir}"
    fi
}
trap cleanup EXIT

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || fail "please run as root (sudo)."
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

read_config() {
    read -r -p "User to start app ${app_title}? (default: ${app}): " app_user < /dev/tty
    app_user="${app_user//[[:space:]]/}"
    app_user="${app_user:-$app}"

    read -r -p "Group to start app ${app_title}? (default: media): " app_group < /dev/tty
    app_group="${app_group//[[:space:]]/}"
    app_group="${app_group:-media}"

    [[ "${app_user}" =~ ^[a-z_][a-z0-9_-]*$ ]] || fail "username invalid: ${app_user}"
    [[ "${app_group}" =~ ^[a-z_][a-z0-9_-]*$ ]] || fail "group invalid: ${app_group}"

    echo
    echo "Install to: ${install_dir}"
    echo "Data: ${data_dir}"
    echo "User and Group: ${app_user}:${app_group}"
    echo
    read -r -p "Continue? [y/N] " answer < /dev/tty
    [[ "${answer}" =~ ^[Yy]$ ]] || exit 0
}

install_packages() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y \
        ca-certificates \
        curl \
        python3 \
        python3-venv \
        python3-dev \
        unzip \
        7zip \
        unrar-free \
        ffmpeg \
        libxml2-dev \
        libxslt1-dev \
        python3-lxml \
        python3-setuptools

}

create_account() {
    getent group "${app_group}" >/dev/null || groupadd --system "${app_group}"

    if ! getent passwd "${app_user}" >/dev/null; then
        useradd --system --no-create-home --home-dir "${data_dir}" \
            --shell /usr/sbin/nologin --gid "${app_group}" "${app_user}"
    else
        usermod -g "${app_group}" "${app_user}"
    fi
}

stop_service() {
    if systemctl cat "${app}.service" >/dev/null 2>&1; then
        systemctl stop "${app}.service" || true
    fi
}

get_latest_version() {
    local version
    version="$(curl -fsSL --retry 3 --retry-delay 2 \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        "${release_api}" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
    [[ -n "${version}" ]] || fail "unable to get latest release from GitHub."
    printf '%s\n' "${version}"
}

download_and_install() {
    local version="${1}"
    local archive="${tmp_dir}/bazarr.zip"
    local extracted="${tmp_dir}/extracted"
    local staging="${tmp_dir}/bazarr-install"

    mkdir -p "${extracted}" "${staging}"
    echo "Downloading Bazarr ${version}..."
    curl -fL --retry 3 --retry-delay 2 "${release_asset_url}" -o "${archive}"
    unzip -q "${archive}" -d "${extracted}"

    if [[ -f "${extracted}/bazarr.py" ]]; then
        cp -a "${extracted}/." "${staging}/"
    elif [[ -f "${extracted}/bazarr/bazarr.py" ]]; then
        cp -a "${extracted}/bazarr/." "${staging}/"
    else
        fail "bazarr.py not found in archive."
    fi

    [[ -f "${staging}/requirements.txt" ]] || fail "requirements.txt not found in archive."

    old_install_dir="${tmp_dir}/old-install"
    if [[ -d "${install_dir}" ]]; then
        mv -- "${install_dir}" "${old_install_dir}"
    fi
    mkdir -p "${install_dir}"
    cp -a "${staging}/." "${install_dir}/"

    python3 -m venv --clear "${venv_dir}"
    "${venv_dir}/bin/python" -m pip install --upgrade pip setuptools wheel
    "${venv_dir}/bin/python" -m pip install --requirement "${install_dir}/requirements.txt"

    printf '%s\n' "${version}" > "${install_dir}/VERSION"
}

write_service() {
    cat > "${service_file}" <<EOF
[Unit]
Description=Bazarr Daemon
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=${install_dir}
User=${app_user}
Group=${app_group}
UMask=${app_umask}
Type=simple
ExecStart=${venv_dir}/bin/python ${install_dir}/bazarr.py
KillSignal=SIGINT
TimeoutStopSec=20
Restart=on-failure
RestartSec=5
SyslogIdentifier=bazarr

[Install]
WantedBy=multi-user.target
EOF
}

set_permissions() {
    mkdir -p "${data_dir}"
    chown -R "${app_user}:${app_group}" "${install_dir}" "${data_dir}"
    chmod 0755 "${install_dir}"
    chmod 0775 "${data_dir}"
}

main() {
    require_root
    echo "Running ${app_title} install script ${scriptversion} (${scriptdate})"

    read_config
    install_packages
    create_account
    stop_service

    tmp_dir="$(mktemp -d -t bazarr-install.XXXXXX)"
    latest_version="$(get_latest_version)"
    echo "Last detected release: ${latest_version}"
    download_and_install "${latest_version}"
    set_permissions
    write_service

    systemctl daemon-reload
    systemctl enable --now "${app}.service"

    sleep 3
    if systemctl is-active --quiet "${app}.service"; then
        ip_local="$(hostname -I | awk '{print $1}')"
        echo
        echo "Install complete."
        echo "Version: ${latest_version}"
        echo "GUI: http://${ip_local}:${app_port}/"
        echo "Check the log: journalctl -u ${app}.service -f"
    else
        echo "Bazarr not started, check journal:" >&2
        journalctl -u "${app}.service" -n 50 --no-pager >&2 || true
        exit 1
    fi
}

main "$@"
