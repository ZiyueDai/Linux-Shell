#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# ===== Color Definition =====
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
PURPLE="\033[35m"
RESET="\033[0m"
BOLD="\033[1m"

# ===== Log Level =====
log_info()  { printf "\n${BOLD}${BLUE}[INFO] %s${RESET}\n" "$1"; }
log_ok()    { printf "\n${BOLD}${GREEN}[OK] %s${RESET}\n" "$1"; }
log_warn()  { printf "\n${BOLD}${YELLOW}[WARN] %s${RESET}\n" "$1"; }
log_error() { printf "\n${BOLD}${RED}[ERROR] %s${RESET}\n" "$1"; }

# ===== get_ccd_om_sp =====
read -rp "Please enter CCD_OM_SP VIP for target CCD cluster: " CCD_OM_SP

if [[ -z "$CCD_OM_SP" ]]; then
    echo "ERROR: CCD VIP cannot be empty!"
    exit 1
fi

echo "Using CCD VIP: $CCD_OM_SP"

# ===== Parameter Initial =====
#current_ccdadm_version=$(ssh -o StrictHostKeyChecking=no "root@$CCD_OM_SP" "cat /etc/eccd/eccd_image_version.ini | grep -i release | awk -F '=' '{print \$2}'")
ccd_nodes=$(ssh -o StrictHostKeyChecking=no "root@$CCD_OM_SP" "kubectl get nodes -owide --no-headers | awk '{print \$6}'")

# ===== Print Command =====
print_cmd() {
    printf "\n${BOLD}${PURPLE}[COMMAND]${RESET} %s\n" "$1";
}

#  ===== Check CCD Version =====
#  ===== Check if the current CCD cluster in the newer version than 2.30.0 =====
select_command_for_2_30_0() {
    local CMD_Newer_Than_2_30_0="$1"
    local CMD_Older_Than_2_30_0="$2"
    local target_ccdadm_version
    target_ccdadm_version="2.30.0"

    if [[ "$(printf "%s\n" "$current_ccdadm_version" "$target_ccdadm_version" | sort -V | head -n 1)" == "$target_ccdadm_version" ]]; then
      echo "$CMD_Newer_Than_2_30_0"
    else
      echo "$CMD_Older_Than_2_30_0"
    fi
}

#  ===== Check if the current CCD cluster in the newer version than 2.31.0 =====
select_command_for_2_31_0() {
    local CMD_Newer_Than_2_31_0="$1"
    local CMD_Older_Than_2_31_0="$2"
    local target_ccdadm_version
    target_ccdadm_version="2.31.0"

    if [[ "$(printf "%s\n" "$current_ccdadm_version" "$target_ccdadm_version" | sort -V | head -n 1)" == "$target_ccdadm_version" ]]; then
      echo "$CMD_Newer_Than_2_31_0"
    else
      echo "$CMD_Older_Than_2_31_0"
    fi
}

# ===== local_run_check function =====
local_check() {
    local DESC="$1"
    local CMD="$2"

    log_info "$DESC"
    print_cmd "$CMD"

    if bash -c "$CMD"; then
      log_ok "$DESC completed"
    else
      log_error "$DESC failed"
    fi
}

# ===== remote_check_on_ctrl function =====
remote_check_on_ctrl() {
    local DESC="$1"
    local CMD="$2"

    log_info "$DESC"
    print_cmd "$CMD"
    local ssh_cmd=("ssh" "-o" "StrictHostKeyChecking=no" "root@$CCD_OM_SP" "$CMD")

    if "${ssh_cmd[@]}"; then
        log_ok "$DESC completed"
    else
        log_error "$DESC failed"
    fi
}

# ===== remote_check_on_all_nodes function =====
# ===== remote_check_on_all_nodes function =====
remote_check_on_all_nodes() {
    local DESC="$1"
    local CMD="$2"

    log_info "$DESC on all CCD nodes"

    # 将需要的函数定义导出为变量
    local log_functions=$(declare -f log_info log_ok log_warn log_error print_cmd)
    local color_vars=$(declare -p RED GREEN YELLOW BLUE PURPLE RESET BOLD 2>/dev/null || true)

    ssh -o StrictHostKeyChecking=no "root@$CCD_OM_SP" bash -s <<EOF
$color_vars
$log_functions

NODES="$ccd_nodes"
DESC="$DESC"
CMD="$CMD"

for NODE in \$NODES; do
    log_info "\$DESC on \$NODE"
    print_cmd "\$CMD"

    if ssh -q \$NODE "\$CMD"; then
        log_ok "\$DESC on \$NODE completed"
    else
        log_error "\$DESC on \$NODE failed"
    fi
done
EOF

    if [[ $? -eq 0 ]]; then
        log_ok "$DESC completed"
    else
        log_error "$DESC failed"
    fi
}



echo "=========================================="
echo "   CCD Health Check"
echo "   Time: $(date)"
echo "=========================================="

# ===== 1. Backup Part =====
# ===== 1.1 Get CCD Version =====
get_ccd_version() {
    remote_check_on_all_nodes "Get CCD Version" "cat /etc/eccd/eccd_image_version.ini"
}

# ===== 1.2 Get IP Interface on all CCD Nodes =====
get_ip_interface() {
    remote_check_on_all_nodes "Get IP Interface" "ip a"
}

# ===== 1.3 Get IP Route on all CCD Nodes =====
get_ip_route() {
    remote_check_on_all_nodes "Get IP Route" "ip r"
}

# ===== 1.4 Get /etc/hosts on all CCD Nodes =====
get_hosts_file() {
    remote_check_on_all_nodes "Get /etc/hosts" "cat /etc/hosts"
}

# ===== 1.5 Get resolv.conf on all CCD Nodes =====
get_DNS_server_info() {
    remote_check_on_all_nodes "Get resolv.conf" "cat /etc/resolv.conf"
}

# ===== 2. CCD General Health Check Part =====
# ===== 2.1 Run CCDADM Cluster Healthcheck=====
ccdadm_cluster_hc() {
    local_check "CCDADM Cluster Healthcheck" "ccdadm cluster healthcheck"
}

# ===== 2.2 Access Active Alarm List =====
access_active_alarm() {
    local CMD_Newer_Than_2_30_0='curl -sk https://$(kubectl get svc/eric-pm-alertmanager -n monitoring -o jsonpath='\''{.spec.clusterIP}'\''):9093/api/v2/alerts | jq'
    local CMD_Older_Than_2_30_0='curl -sk http://$(kubectl get svc/eric-pm-alertmanager -n monitoring -o jsonpath='\''{.spec.clusterIP}'\''):9093/api/v1/alerts | jq'
    CMD=$(select_command_for_2_30_0 "$CMD_Newer_Than_2_30_0" "$CMD_Older_Than_2_30_0")
    remote_check_on_ctrl "Access Active Alarm List" "$CMD"
}

# ===== 2.3 Get CCD Nodes =====
get_ccd_nodes() {
    remote_check_on_ctrl "Get CCD Nodes" "kubectl get nodes -owide"
}

# ===== 2.4 Get BMH Status =====
get_bmh_status() {
    remote_check_on_ctrl "Get BMH Status" "kubectl get bmh -A"
}

# ===== 2.5 Get Machine Status =====
get_machine_status() {
    remote_check_on_ctrl "Get Machine Status" "kubectl get machine -A"
}

# ===== 2.6 Get PDB Status =====
get_PDB_status() {
    remote_check_on_ctrl "Get All PDB Status" "kubectl get pdb -A"

    log_warn "Check Problematic PDB"
    local check_cmd='kubectl get pdb -A -o custom-columns=Namespace:.metadata.namespace,Name:.metadata.name,MinAvailable:.spec.minAvailable,MaxUnavailable:.spec.maxUnavailable,AllowedDisruptions:.status.disruptionsAllowed,CurrentHealthy:.status.currentHealthy,DesiredHealthy:.status.desiredHealthy,Expected:.status.expectedPods | awk '"'"'NR==1 || ($5=="0" && $8!="0")'"'"
    print_cmd "$check_cmd"
    local output
    output=$(ssh -o StrictHostKeyChecking=no "root@$CCD_OM_SP" "$check_cmd" | tail -n +2 || true)
    if [[ -z "$output" ]]; then
        log_ok "No Potential PDB Problem!"
    else
        log_warn "Problematic PDB List:"
        echo "$output"
    fi
}

# ===== 2.7 Get Pods from All Namespaces =====
get_pod_status() {
    log_info "Get Pod List from All Namespaces"
    local check_cmd='kubectl get ns --no-headers | awk '\''{print $1}'\'''
    ns=$(ssh -o StrictHostKeyChecking=no "root@$CCD_OM_SP" "$check_cmd")
    for ns in $ns; do
      remote_check_on_ctrl "Get Pods from Namespaces: $ns" "kubectl get pods -owide -n $ns"
    done

    log_warn "Checking Problematic PODs"
    local check_cmd='kubectl get pods -A -o wide | grep -iv Running| grep -iv Completed'
    print_cmd "$check_cmd"
    local output
    output=$(ssh -o StrictHostKeyChecking=no "root@$CCD_OM_SP" "$check_cmd" | tail -n +2 || true)
    if [[ -z "$output" ]]; then
        log_ok "All pods are running well!"
    else
        log_warn "Pods in abnormal status:"
        echo "$output"
    fi

    log_warn "Check if pods are fully running"
    local check_cmd='kubectl get pod -A | awk -F"[ /]+" '\''BEGIN{found=0} !/NAME/ {if ($3!=$4) { found=1; print $0}}'\'''
    print_cmd "$check_cmd"
    local output
    output=$(ssh -o StrictHostKeyChecking=no "root@$CCD_OM_SP" "$check_cmd" | tail -n +2 || true)
    if [[ -z "$output" ]]; then
        log_ok "All Containers are UP!"
    else
        log_warn "Pods who has container in abnormal status:"
        echo "$output"
    fi
}

# ===== 2.8 Get SVC Status =====
get_svc_status() {
    remote_check_on_ctrl "Get SVC Status" "kubectl get svc -A"

    log_warn "Check if any SVC is in pending status"
    local check_cmd='kubectl get svc -A | grep -i pending'
    print_cmd "$check_cmd"
    local output
    output=$(ssh -o StrictHostKeyChecking=no "root@$CCD_OM_SP" "$check_cmd" | tail -n +2 || true)
    if [[ -z "$output" ]]; then
        log_ok "No SVC is in pending state!"
    else
        log_warn "Pending SVC:"
        echo "$output"
    fi
}

# ===== 2.9 Get ETCD Status =====
get_etcd_status() {
    remote_check_on_ctrl "Get ETCD Member List" 'sudo bash -c ". /etc/profile.d/etcdctl.sh && etcdctl3 member list"'
    remote_check_on_ctrl "Get ETCD Endpoint List" 'sudo bash -c ". /etc/profile.d/etcdctl.sh && etcdctl3 endpoint status --cluster -wtable"'
    remote_check_on_ctrl "Check ETCD Endpoint Health" 'sudo bash -c ". /etc/profile.d/etcdctl.sh && etcdctl3 endpoint health --cluster -wtable"'
}

# ===== 2.10 Check BGP Session Status =====
get_bgp_status() {
    remote_check_on_ctrl "Check BGP Session Status" 'for i in $(kubectl get pods -n kube-system | grep -i speak | awk '\''{print $1}'\'') ;  do echo $i; kubectl exec $i -n kube-system -- birdcl show pr ;  done'
    remote_check_on_ctrl "Check BFD Session Status" 'for i in $(kubectl get pods -n kube-system | grep -i speak | awk '\''{print $1}'\'') ;  do echo $i; kubectl exec $i -n kube-system -- birdcl show bfd session;  done'
}

# ===== 2.11 Check kubeadm cert expiration =====
get_kubeadm_cert_info() {
    remote_check_on_ctrl "Check kubeadm cert expiration" 'sudo /usr/local/bin/kubeadm certs check-expiration'
}

# ===== 2.12 Check CEPH Cluster Status =====
get_ceph_cluster_status() {
    local CMD_Newer_Than_2_31_0='/var/lib/eccd/ceph_cli.sh ceph'
    local CMD_Older_Than_2_31_0='/var/lib/eccd/ceph_cli.sh'
    CMD=$(select_command_for_2_31_0 "$CMD_Newer_Than_2_31_0" "$CMD_Older_Than_2_31_0")
    run_check "Check CEPH SW Version" "$CMD version"
    run_check "Check CEPH Status" "$CMD -s"
    run_check "Check CEPH Pool Storage Usage" "$CMD df"
    run_check "Check CEPH OSD Storage Usage_1" "$CMD osd df"
    run_check "Check CEPH OSD Storage Usage_2" "$CMD osd utilization"
    run_check "Check CEPH OSD Tree" "$CMD osd tree"
    run_check "Check CEPH Device List" "$CMD device ls"
    run_check "Check CEPH Quorum Status" "$CMD quorum_status --format json-pretty"
    run_check "Check CEPH MON Status" "$CMD mon stat"
    run_check "Check CEPH MDS Status" "$CMD mds stat"
}

# ===== 2.13 Check NTP status =====
get_ntp_status() {
    local CMD='echo "=== timedatectl ==="; timedatectl | grep NTP; timedatectl | grep synchronized; echo; echo "=== chronyc sources ==="; chronyc sources'
    remote_check_on_all_nodes "Check NTP Status on All CCD Nodes" "$CMD"
}

# ===== 2.14 Check Latest Log of Pod ccd-license-consumer =====
get_license_consumer_log() {
    local CMD='kubectl logs -n kube-system $(kubectl get pods -n kube-system -o name | grep ccd-license-consumer) | grep -A 2 "Requesting license" | tail -n 10'
    remote_check_on_ctrl "Get Latest Log of Pod ccd-license-consumer" "$CMD"
}

# ===== 2.15 Get Deploy eric-app-sys-info-handler Info =====
get_sys_info_handler_info() {
    remote_check_on_ctrl "Get Deploy eric-app-sys-info-handler Info" "kubectl describe deployments eric-app-sys-info-handler -n kube-system"
}



# ===== Definition for Two Options `-c` and `-b` =====
if [[  $# -eq 0 ]]; then
    log_info "No option specified, Running all Check...."
    log_info "Part 1 : Backup Part"
    get_ccd_version
    get_ip_interface
    get_ip_route
    get_hosts_file
    get_DNS_server_info
    log_info "Part 2 : Health Check Part"
    access_active_alarm
    get_ccd_nodes
    get_bmh_status
    get_machine_status
    get_PDB_status
    get_pod_status
    get_svc_status
    get_etcd_status
    get_bgp_status
    get_kubeadm_cert_info
    get_ceph_cluster_status
    get_ntp_status
    get_license_consumer_log
    get_sys_info_handler_info
    ccdadm_cluster_hc

else
    case "$1" in
      -c)
#        access_active_alarm
        get_ccd_nodes
        get_bmh_status
        get_machine_status
        get_PDB_status
        get_pod_status
        get_svc_status
        get_etcd_status
        get_bgp_status
#        get_kubeadm_cert_info
#        get_ceph_cluster_status
        get_ntp_status
        get_license_consumer_log
        get_sys_info_handler_info
        ccdadm_cluster_hc
        ;;
      -b)
        get_ccd_version
        get_ip_interface
        get_ip_route
        get_hosts_file
        get_DNS_server_info
    esac
fi
