#!/bin/bash
################################################################################
# @brief:       Launcher/entrypoint script plus helper functions for "server
#               side" container in the VPP testbench.
# @author:      Matthew Giassa <mgiassa@cisco.com>
# @copyright:   (C) Cisco 2021.
################################################################################

################################################################################
# Dependencies.
################################################################################
# Import common settings for server and client. This is supplied via the
# Dockerfile build.
# shellcheck disable=SC1091
. vpp_testbench_helpers.sh

################################################################################
# Globals.
################################################################################
# VPP instance socket.
export VPP_SOCK=/run/vpp/server_ddos.sock
# Alias for vppctl that uses the correct socket name.
export VPPCTL="vppctl -s ${VPP_SOCK}"
# Our "Docker bridge network". Don't change this value.
export NET_IF_DOCKER="eth0"
# Name of link associated with our VXLAN.
export LINK_VXLAN_LINUX="vxlan-vid-${VXLAN_ID_LINUX}"

################################################################################
# Function definitions.
################################################################################
#------------------------------------------------------------------------------#
# @brief:   Alias for vppctl (knowing which API socket to use).
function vc()
{
    vppctl -s "${VPP_SOCK}" "${@}"
}

#------------------------------------------------------------------------------#
# @brief:   Used to initialize/configure the server container once it's up and
#           running.
function context_create()
{
    set -x
    echo "Running server. Host: $(hostname)"
    local mtu

    # Setup VXLAN overlay.
    ip link add "${LINK_VXLAN_LINUX}" \
        type vxlan \
        id "${VXLAN_ID_LINUX}" \
        dstport "${VXLAN_PORT}" \
        local "${SERVER_DDOS_IP_DOCKER}" \
        group "${MC_VXLAN_ADDR_LINUX}" \
        dev "${NET_IF_DOCKER}" \
        ttl 1
    ip link set "${LINK_VXLAN_LINUX}" up
    ip addr add "${SERVER_DDOS_VXLAN_IP_LINUX}/${MASK_VXLAN_LINUX}" dev "${LINK_VXLAN_LINUX}"

    # Get MTU of interface. VXLAN must use a smaller value due to overhead.
    mtu="$(cat /sys/class/net/${NET_IF_DOCKER}/mtu)"

    # Decrease VXLAN MTU. This should already be handled for us by iproute2, but
    # just being cautious.
    ip link set dev "${LINK_VXLAN_LINUX}" mtu "$((mtu - 50))"

    # Bring-up VPP and create tap interfaces and VXLAN tunnel.
    vpp \
        unix '{' log /tmp/vpp1.log full-coredump cli-listen ${VPP_SOCK} '}' \
        api-segment '{' prefix vpp1 '}' \
        api-trace '{' on '}' \
        dpdk '{' uio-driver uio_pci_generic no-pci '}'

    # Wait for VPP to come up.
    while ! ${VPPCTL} show log; do
        sleep 1
    done

    # Bring up the memif interface and assign an IP to it.
    ${VPPCTL} create interface memif id 0 master
    sleep 1
    ${VPPCTL} set int state memif0/0 up
    ${VPPCTL} set int ip address memif0/0 "${SERVER_DDOS_VPP_TAP_IP_MEMIF}/${VPP_MEMIF_NM}"

    # Create VPP-controlled tap interface bridged to the memif.
    ${VPPCTL} create tap id 0 host-if-name vpp-tap-0
    sleep 1
    ${VPPCTL} set interface state tap0 up
    ip addr add "${SERVER_DDOS_VPP_TAP_IP_MEMIF}/${VPP_TAP_NM}" dev vpp-tap-0
    ${VPPCTL} set interface l2 bridge tap0          "${VPP_BRIDGE_DOMAIN_TAP}"
    ${VPPCTL} set interface l2 bridge memif0/0      "${VPP_BRIDGE_DOMAIN_TAP}"
}

#------------------------------------------------------------------------------#
# @brief:   Used to shutdown/cleanup the server container.
function context_destroy()
{
    # OS will reclaim interfaces and resources when container is terminated.
    :
}

#------------------------------------------------------------------------------#
# @brief:   Server worker loop to keep the container alive. Just idles.
function context_loop()
{
    # Sleep indefinitely (to keep container alive for testing).
    # tail -f /dev/null

    # iperf -s -V
    answer="HTTP/1.1 200 OK\n
    <html><body><h1>It works!</h1></body></html>"
    sudo socat tcp-listen:80,reuseaddr,fork "exec:printf \'${answer}\'"
}


function configure_snort_sniff()
{
   sudo cat /etc/snort/snort.conf | grep -Fn "ipvar HOME_NET any" | awk -F ':' '{print $1}' | { read number; sed -i "${number}s/.*/ipvar HOME_NET ${SERVER_DDOS_VXLAN_IP_LINUX}\/32/" /etc/snort/snort.conf; }
   sudo cat /etc/snort/snort.conf | grep -Fn "ipvar EXTERNAL_NET any" | awk -F ':' '{print $1}' | { read number; sed -i "${number}s/.*/ipvar EXTERNAL_NET !\$HOME_NET/" /etc/snort/snort.conf; }
   sudo cat /etc/snort/snort.conf | grep -Fn "var RULE_PATH ../rules" | awk -F ':' '{print $1}' | { read number; sed -i "${number}s/.*/var RULE_PATH rules/" /etc/snort/snort.conf; }
   sudo cat /etc/snort/snort.conf | grep -Fn "var SO_RULE_PATH ../so_rules" | awk -F ':' '{print $1}' | { read number; sed -i "${number}s/.*/var SO_RULE_PATH so_rules/" /etc/snort/snort.conf; }
   sudo cat /etc/snort/snort.conf | grep -Fn "var PREPROC_RULE_PATH ../preproc_rules" | awk -F ':' '{print $1}' | { read number; sed -i "${number}s/.*/var PREPROC_RULE_PATH preproc_rules/" /etc/snort/snort.conf; }
   sudo cat /etc/snort/snort.conf | grep -Fn "var WHITE_LIST_PATH ../rules" | awk -F ':' '{print $1}' | { read number; sed -i "${number}s/.*/var WHITE_LIST_PATH rules/" /etc/snort/snort.conf; }
   sudo cat /etc/snort/snort.conf | grep -Fn "var BLACK_LIST_PATH ../rules" | awk -F ':' '{print $1}' | { read number; sed -i "${number}s/.*/var BLACK_LIST_PATH rules/" /etc/snort/snort.conf; }
   # sudo snort -T -c /etc/snort/snort.conf
   
   sudo cat /etc/snort/rules/ddos_rules.txt >> /etc/snort/rules/local.rules
   # sudo echo "event_filter gen_id 1, sig_id 10000001, type threshold, track by_src, count 100, seconds 3" >> /etc/snort/threshold.conf

   sudo cat /etc/snort/snort.conf
   sudo snort -A console -i ${LINK_VXLAN_LINUX} -u snort -g snort -c /etc/snort/snort.conf
   sudo snort -A console -i vpp-tap-0 -u snort -g snort -c /etc/snort/snort.conf
}

#------------------------------------------------------------------------------#
# @brief:   Main/default entry point.
function main()
{
    # Make sure we always cleanup.
    trap context_destroy EXIT

    # Bring up interfaces.
    context_create

    # Configure Snort to detect flooding
    configure_snort_sniff &
    
    # Enter our worker loop.
    context_loop
}

#------------------------------------------------------------------------------#
# Script is generally intended to be sourced and individual functions called.
# If just run as a standalone script, assume it's being used as the entrypoint
# for a Docker container.
if [ "${BASH_SOURCE[0]}" -ef "$0" ]; then
    # Being run. Launch main.
    main "${@}"
else
    # Being sourced. Do nothing.
    :
fi

