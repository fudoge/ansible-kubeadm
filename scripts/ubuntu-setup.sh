#!/usr/bin/env bash

set -euo pipefail

[ "$EUID" -ne 0 ] && echo "root account required" && exit 1

# References
# https://kubernetes.io/ko/docs/setup/production-environment/container-runtimes/
# https://kubernetes.io/ko/docs/setup/production-environment/tools/kubeadm/install-kubeadm/

K_MINOR="v1.35"
PAUSE="registry.k8s.io/pause:3.10.1"

# Update and upgrade packages
apt update
apt upgrade -y

# Disable swap
swapoff -a
sed -i '/swap/d' /etc/fstab

# IPv4 forwarding
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF

## Apply sysctl parameters
sysctl --system

# Add Docker's official GPG key
apt install ca-certificates gnupg lsb-release -y
apt update
apt install ca-certificates curl -y
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Add Docker APT repository
sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

# Install containerd
apt update
apt install containerd.io -y

# CGroup Setup
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

## Replace Sandbox Image
sed -i "s|^\s*sandbox_image\s*=.*|sandbox_image = \"${PAUSE}\"|" /etc/containerd/config.toml

## Restart to apply
systemctl restart containerd

# Install kubectl, kubelet, kubeadm
apt install apt-transport-https ca-certificates curl gpg -y

curl -fsSL https://pkgs.k8s.io/core:/stable:/${K_MINOR}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K_MINOR}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

systemctl enable --now kubelet
