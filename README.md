# Kubernetes Cluster with Ansible

## Table of Contents

- [Kubernetes Cluster with Ansible](#kubernetes-cluster-with-ansible)
  - [Ansible 시작을 위한 기본 세팅](#ansible-시작을-위한-기본-세팅)
    - [각 서버에 ansible 유저 생성](#각-서버에-ansible-유저-생성)
    - [ssh 키 생성](#ssh-키-생성)
    - [로컬에서 각 서버로 키 배포](#로컬에서-각-서버로-키-배포)
  - [ansible.cfg 및 inventory.ini 작성](#ansiblecfg-및-inventoryini-작성)
    - [ansible.cfg 예시](#ansiblecfg-예시)
    - [inventory.ini 예시](#inventoryini-예시)
  - [Ansible을 이용한 모든 노드들에 대해 필수 구성요소 설치](#ansible을-이용한-모든-노드들에-대해-필수-구성요소-설치)
    - [준비사항](#준비사항)
    - [순서](#순서)
    - [설치하기](#설치하기)
  - [Control Plane 초기화](#control-plane-초기화)
    - [단일 Control Plane 구성](#단일-control-plane-구성)
    - [HA구성](#HA구성)
  - [네트워크 플러그인 설치(Cilium)](#네트워크-플러그인-설치cilium)
    - [기존 kube-proxy제거](#기존-kube-proxy-제거)
    - [cilium CLI를 이용한 설치](#cilium-cli를-이용한-설치)
    - [helm을 이용한 설치](#helm을-이용한-설치)
    - [설치 확인](#설정-확인)
    - [연결 테스트하기](#연결-테스트하기)
  - [Worker Node 조인시키기](#worker-node-조인시키기)
  - [관리자 자격 증명 가져오기](#관리자-자격-증명-가져오기)
    - [처음 kubectl을 사용하는 경우](#처음-kubectl을-사용하는-경우)
    - [기존 config에 context를 추가하는 경우](#기존-config에-context를-추가하는-경우)
  - [(Optional) 기존 클러스터의 data 암호화하기](<#(Optional)-기존-클러스터의-data-암호화하기>)
  - [CLI 도구 모음](#CLI-도구-모음)
  - [추가예정중인 정보 및 수정할 것들](#추가예정중인-정보-및-수정할-것들)

본 문서는 다음의 작업에 대해 설명합니다:

- **Ansible** 을 활용하여 쿠버네티스 클러스터의 필수 요소 설치를 자동화
  - `containerd`
  - `kubelet`
  - `kubeadm`
  - `kubectl`
- kubeadm으로 Control Plane 구성
- Cilium을 **CNI(Container Network Interface)** 플러그인으로 설치
- 마스터 자격 증명 가져오기

Ansible은 Red Hat의 오픈 소스 IaC도구로, 서버 자원의 구성 관리를 자동화하여 휴먼 에러를 줄이고, 생산성을 높여줍니다.

Ansible은 다음의 장점을 가집니다:

- YAML기반으로 **IaC(Infrastructure as Code)** 실현
- **멱등성(Idempotence)** - 여러 번 실행해도 크래시가 생기지 않습니다
  - 그러나, 이미 생성된 클러스터의 노드에 대해서 다시 실행하면, 오류가 발생할 수 있습니다.
  - 기본 필요사항들의 설치까지만 보장됩니다.
  - 노드를 추가하고 싶을 시, 인벤토리에 기존 노드들은 제거하고 돌리시는게 좋습니다

## Ansible 시작을 위한 기본 세팅

Ansible의 구성 요소는 다음과 같습니다:

- `controller`
  - 구성 대상이 되는 서버들에게 명령을 내리는 호스트
- `inventory`
  - 대상 서버들에 대한 정보
- `playbook`
  - 대상 서버들에 대한 명령집 파일
  - playbook은 여러 개의 play들로 구성
  - **각 play에는 1개 이상의 task로 구성됨**
  - **각 play마다 대상 host가 있음**

Ansible은 대상 서버에서 작업을 취하기 위해, ssh로 접속하여 동작합니다.

즉, Ansible이 접속할 수 있는 사용자를 대상 서버에서 만들어줘야 합니다.

각 서버에 아래의 작업들을 해야 합니다:

### 각 서버에 ansible 유저 생성

`adduser`로 사용자를 생성합니다.

`useradd` 를 내부적으로 사용하며, 최초 비밀번호 초기화 등의 더 많은 기능들을 제공합니다.

```bash
adduser ansible
```

쿠버네티스 설치를 위해, 권한이 필요합니다.

또한, 완전한 자동화를 위해 패스워드 입력을 생략시킬 것입니다.

```bash
sudo visudo -f /etc/sudoers.d/ansible.conf
#/etc/sudoers.d/ansible에서 아래와 같이 작성
ansible ALL=(ALL) NOPASSWD: ALL

# ansible 사용자는
# 모든 명령어를 sudo권한으로 사용가능하며
# 모든 명령어를 비밀번호 없이 사용가능하다
# 실제로는 최소권한을 주는 것이 낫다.
```

### ssh 키 생성

(로컬, 즉 컨트롤러에서) ssh key를 생성한다.

```bash
ssh-keygen -N '' -f ~/.ssh/id_rsa -b 2048 -t rsa

# no passphrase
# save private key to ~/.ssh/id_rsa
# 2048 b
# type rsa
```

### 로컬에서 각 서버로 키 배포

```bash
ssh-copy-id -i <key-file> -p <port> ansible@<server-ip>
```

## ansible.cfg 및 inventory.ini 작성

Ansible은 `/etc/ansible/ansible.cfg`의 값을 기본적으로 참조하지만,

현재 작업 디렉토리에서의 `ansible.cfg`가 있다면, 그 설정 파일을 우선으로 읽습니다.

- `ansible.cfg`는 ansible명령을 실행할 때의 환경 설정 파일입니다.
- `inventory.ini`는 대상 호스트들의 정보가 담겨있는 파일입니다.

### ansible.cfg 예시

```ini
[defaults]
inventory = ./inventory.ini # inventory.ini이 이번에 쓸 인벤토리 파일이다
remote_user = ansible # ssh 유저는 ansible
aks_pass = false # 패스워드 묻지 않음(SSH키 이용)

[privilege_escalation]
become = true # 권한 상승 허용
become_method = sudo # 권한 상승 방법은 sudo(sudo > su)
become_user = root # 권한 상승되어 root로서 동작
become_ask_pass = false # 권한 상승 비밀번호를 묻지 않음. true로 두면
```

### inventory.ini 예시

```ini
[masters]
master ansible_host=192.168.64.10 ansible_port=22

[workers]
worker1 ansible_host=192.168.64.12 ansible_port=22

[k8s-nodes:children] # 호스트 그룹 상속
masters
workers
```

또는, `~/.ssh/config` 파일에서 정리해두면, 해당 hostname을 간단하게 쓸 수 있습니다.

## Ansible을 이용한 모든 노드들에 대해 필수 구성요소 설치

본격적으로 쿠버네티스를 설치합니다.

각 노드들은 ubuntu 24.04를 기준으로 합니다.

### 준비사항

사전 확인 할것들은 다음과 같습니다:

- 2GB이상 RAM
- 2코어 이상의 CPU/vCPU
- 클러스터 전체는 네트워크에 연결되어야 함(퍼블릭/프라이빗 상관없음)
- MAC주소 및 `product_uuid`가 모두 고유해야 함
  - `ip link` 또는 `ifconfig -a`로 MAC주소 확인
    - `sudo cat/sys/class/dmi/id/product_uuid`로 `product_uuid`확인 가능
- hostname이 모두 고유해야 함
- 시간이 알맞게 동기화되어있어야 함
- 네트워크 어댑터가 2개 이상인 경우, 신경써야 함
  - 기본 라우트 설정 등
- 스왑 비활성화(kubelet이 제대로 작동하려면 스왑은 꺼야 함) → 플레이북에서 자동화한다
- 6443포트가 방화벽에 막히지는 않는지 확인해야 함(kube-apiserver 위해)
  - iptables/firewalld, 보안 그룹 등
  - cni에 따라 추가로 필요한 게 있을 수 있음

### 순서

1. 시스템 업데이트 및 업그레이드
2. NTP서버 동기화(현재 플레이북에 없음)
3. ufw비활성화(현재 플레이북에 없음)
4. 스왑 제거
5. 커널 설정 변경(br_netfilter, overlay, iptables, forwarding)
   - `br_netfilter`는 브릿지 네트워크 패킷을 `iptables`에서 볼 수 있게 해줍니다
   - `overlay`는 컨테이너의 파일 시스템인 overlayfs를 사용할 수 있도록 해줍니다
   - `net.ipv4.ip_forward`로 ipv4 패킷 포워딩을 활성화합니다
   - `net.bridge-nf-call-iptables`, `net.bridge-nf-call-ip6tables`을 활성화하여 리눅스 브릿지를 통과하는 IPv4 및 IPv6 트래픽이 `iptables`의 규칙을 통과하도록 해줍니다
6. 컨테이너 런타임 설치(containerd)
   - containerd는 Docker로부터 제공받을 수 있습니다
7. `containerd` 초기 설정 + cgroup설정(`SystemdCgroup=true`) + 재시동
   - `systemd`와 통합하여 리소스 제한 및 격리를 관리시킵니다
8. kubelet, kubeadm, kubectl 설치
9. 버전 고정
10. kubelet 실행

### 설치하기

`k8s-install.yml`을 실행하여 플레이북을 실행합니다

```bash
ansible-playbook k8s-install.yml
```

## Control Plane 초기화

### 단일 Control Plane 구성

`kubeadm init`으로 Control Plane을 초기화합니다

```bash
kubeadm init --pod-network-cidr=10.217.0.0/16
```

만약 `kube-proxy`를 처음부터 제외하고 싶다면, `--skip-phases=addon/kube-proxy` 옵션을 같이 붙여주면 됩니다.

> [!IMPORTANT] \
> 내부 secret은 기본적으로 평문 저장됩니다. \
> 암호화를 하고 싶다면, `--encryption-provider-config=<경로>` 옵션을 넣어서 암호화 설정 파일을 제공해야 합니다. \
> [아래](<#(Optional)-기존-클러스터의-data-암호화하기>) 에서 암호화 키를 생성하고 암호화 설정 파일 예시를 안내합니다. 처음부터 암호화 설정을 주입하는 경우, etcd백업 및 static pod수정은 필요없습니다.

조금만 기다리면, 아래와 같은 결과가 나옵니다:

```bash
Your Kubernetes control-plane has initialized successfully!

To start using your cluster, you need to run the following as a regular user:

  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config

Alternatively, if you are the root user, you can run:

  export KUBECONFIG=/etc/kubernetes/admin.conf

You should now deploy a pod network to the cluster.
Run "kubectl apply -f [podnetwork].yaml" with one of the options listed at:
  https://kubernetes.io/docs/concepts/cluster-administration/addons/

Then you can join any number of worker nodes by running the following on each as root:

kubeadm join 192.168.0.4:6443 --token <token> \
        --discovery-token-ca-cert-hash sha256:<hash>
```

### HA구성

(미완)

## 네트워크 플러그인 설치

쿠버네티스에는 여러 네트워크 플러그인이 존재합니다

- Flannel
- Calico
- Cilium
- 기타(클라우트 환경 CNI 등)

여기서는 떠오르고 있는 CNI인 **Cilium**을 설치합니다.

Cilium은 L7정책, 네트워크 가시성, 클러스터 메시 등의 기능들을 강력히 제공합니다

### 기존 kube-proxy제거

```bash
kubectl delete ds kube-proxy -n kube-system
```

### cilium CLI를 이용한 설치

Linux 기준

```bash
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}

```

```bash
cilium install --version 1.18.1
```

### helm을 이용한 설치

cilium CLI 대신, helm으로 설치도 가능합니다.

```bash
helm install cilium cilium/cilium --version 1.18.1 \
    --namespace kube-system \
    --set kubeProxyReplacement=true # kube-proxy를 대체하기
```

`cilium/values.yaml`의 값에서 적절히 수정하거나, 그대로 사용할 수 있습니다.  
`k8sServiceHost`는 반드시 수정해주시길 바랍니다.

```bash
helm repo add cilium https://helm.cilium.io/

helm repo update

helm install cilium cilium/cilium \
    -n kube-system \
    -f cilium/values.yaml
```

### 설치 확인

```bash
root@ubuntu:~# cilium status --wait
    /¯¯\
 /¯¯\__/¯¯\    Cilium:             OK
 \__/¯¯\__/    Operator:           OK
 /¯¯\__/¯¯\    Envoy DaemonSet:    OK
 \__/¯¯\__/    Hubble Relay:       disabled
    \__/       ClusterMesh:        disabled

DaemonSet              cilium                   Desired: 1, Ready: 1/1, Available: 1/1
DaemonSet              cilium-envoy             Desired: 1, Ready: 1/1, Available: 1/1
Deployment             cilium-operator          Desired: 1, Ready: 1/1, Available: 1/1
Containers:            cilium                   Running: 1
                       cilium-envoy             Running: 1
                       cilium-operator          Running: 1
                       clustermesh-apiserver
                       hubble-relay
Cluster Pods:          2/2 managed by Cilium
Helm chart version:    1.18.1
Image versions         cilium             quay.io/cilium/cilium:v1.18.1@sha256:65ab17c052d8758b2ad157ce766285e04173722df59bdee1ea6d5fda7149f0e9: 1
                       cilium-envoy       quay.io/cilium/cilium-envoy:v1.34.4-1754895458-68cffdfa568b6b226d70a7ef81fc65dda3b890bf@sha256:247e908700012f7ef56f75908f8c965215c26a27762f296068645eb55450bda2: 1
                       cilium-operator    quay.io/cilium/operator-generic:v1.18.1@sha256:97f4553afa443465bdfbc1cc4927c93f16ac5d78e4dd2706736e7395382201bc: 1
root@ubuntu:~#
```

### 연결 테스트하기

```bash
cilium connectivity test
ℹ️  Monitor aggregation detected, will skip some flow validation steps
✨ [kubernetes] Creating namespace cilium-test-1 for connectivity check...
✨ [kubernetes] Deploying echo-same-node service...
✨ [kubernetes] Deploying DNS test server configmap...
✨ [kubernetes] Deploying same-node deployment...
✨ [kubernetes] Deploying client deployment...
✨ [kubernetes] Deploying client2 deployment...
⌛ [kubernetes] Waiting for deployment cilium-test-1/client to become ready...
⌛ [kubernetes] Waiting for deployment cilium-test-1/client2 to become ready...
⌛ [kubernetes] Waiting for deployment cilium-test-1/echo-same-node to become ready...
⌛ [kubernetes] Waiting for pod cilium-test-1/client-64d966fcbd-72mrh to reach DNS server on cilium-test-1/echo-same-node-65dd6bdb5c-dl4g8 pod...
⌛ [kubernetes] Waiting for pod cilium-test-1/client2-5f6d9498c7-4cdpn to reach DNS server on cilium-test-1/echo-same-node-65dd6bdb5c-dl4g8 pod...
⌛ [kubernetes] Waiting for pod cilium-test-1/client-64d966fcbd-72mrh to reach default/kubernetes service...
⌛ [kubernetes] Waiting for pod cilium-test-1/client2-5f6d9498c7-4cdpn to reach default/kubernetes service...
⌛ [kubernetes] Waiting for Service cilium-test-1/echo-same-node to become ready...
⌛ [kubernetes] Waiting for Service cilium-test-1/echo-same-node to be synchronized by Cilium pod kube-system/cilium-rl58t
⌛ [kubernetes] Waiting for NodePort 192.168.0.4:32364 (cilium-test-1/echo-same-node) to become ready...
ℹ️  Skipping IPCache check
🔭 Enabling Hubble telescope...
⚠️  Unable to contact Hubble Relay, disabling Hubble telescope and flow validation: rpc error: code = Unavailable desc = connection error: desc = "transport: Error while dialing: dial tcp 127.0.0.1:4245: connect: connection refused"
ℹ️  Expose Relay locally with:
   cilium hubble enable
   cilium hubble port-forward&
ℹ️  Cilium version: 1.18.1
🏃[cilium-test-1] Running 123 tests ...

(중략)
.........

✅ [cilium-test-1] All 74 tests (295 actions) successful, 49 tests skipped, 0 scenarios skipped.
```

## Worker Node 조인시키기

`kubeadm init`의 결과로, 아래와 같은 부분이 있는데, 이를 Worker Node에서 실행하면 됩니다.

```bash
kubeadm join <Control-Plane>:6443 --token <token> \
        --discovery-token-ca-cert-hash sha256:<hash>
```

## 관리자 자격 증명 가져오기

context를 내 로컬(개인 PC 및 노트북)에 가져오면, 원격으로 `kubectl`명령어를 사용할 수 있습니다.  
context는 **클러스터 정보 및 자격 증명의 조합** 을 말합니다.

### 처음 kubectl을 사용하는 경우

`kubeadm init`의 결과로, 아래와 같은 부분이 나왔을 겁니다.  
즉, Control Plane의 `/etc/kubernetes/admin.conf`를 자신의 `~/.kube/config`로 가져오면 됩니다.  
`scp`등을 이용할 수 있습니다.

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

### 기존 config에 context를 추가하는 경우

우선, admin의 설정 파일을 로컬로 가져옵니다.

```bash
scp <remote-user>:<control-plane>:/etc/kubernetes/admin.conf ~/admin.conf
```

그 뒤, 기존 설정 파일과 가져온 설정파일을 병합합니다.

```bash
KUBECONFIG=~/.kube/config:~/admin.conf kubectl config view --flatten > ~/merged; mv ~/merged ~/.kube/config
```

(Optional)컨텍스트의 이름을 변경할 수 있습니다.

```bash
kubectl config rename-context kubernetes-admin@kubernetes <새 컨텍스트 이름>
```

---

## (Optional) 기존 클러스터의 data 암호화하기

여기서는 클러스터의 암호화방식으로 `secretbox`를 이용합니다. \
로컬에 파일을 저장하는 방식 중에서는 가장 안전하지만, 가능하다면 KMSv2를 이용하는 것을 권장합니다. \
자세한 내용은 [여기](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)를 참조하세요.

우선, 현재의 ETCD를 백업합니다:

```bash
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /root/etcd-before-secretbox.db
```

이후. 32바이트의 백업 키를 생성합니다.

```bash
head -c 32 /dev/urandom | base64
```

이후, 암호화 설정파일을 작성할 디렉토리를 생성합니다.

```bash
sudo mkdir -p /etc/kubernetes/enc
sudo chmod 700 /etc/kubernetes/enc
```

이후, Control Plane노드에서 `/etc/kubernetes/enc/enc.yaml`에 아래와 같이 작성합니다:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources: # secret과 configmap을 암호화하겠다
      - secrets
      - configmaps
    providers:
      - secretbox:
          keys:
            - name: key1
              secret: <your-key> # 생성한 key를 여기에 주입
      - identity: {} # 만약의 상황을 위해 평문해석으로 fallback
```

이제, apiserver static pod가 읽을 수 있도록 해줘야 합니다. \
`/etc/kubernetes/manifests/kube-apiserver.yaml`에서 다음 내용들을 추가합니다:

`command:`에서 아래를 추가:

```yaml
- --encryption-provider-config=/etc/kubernetes/enc/enc.yaml
```

`volumeMounts:`에서 아래를 추가:

```yaml
- name: enc
  mountPath: /etc/kubernetes/enc
  readOnly: true
```

`volumes:`에서 아래를 추가:

```yaml
- name: enc
  hostPath:
    path: /etc/kubernetes/enc
    type: DirectoryOrCreate
```

저장하면 static pod가 자동으로 재시작됩니다.

> [!WARNING] \
> 만약 Control Plane이 HA로 구성되어있다면, 모든 Control Plane이 같은 암호화 설정을 가져야 합니다.

이제, secret을 테스트삼아 한번 만들어봅니다.

```bash
kubectl create secret generic secretbox-test \
  -n default \
  --from-literal=mykey=mydata
```

etcd에서 다음과 같이 확인해 볼 수 있습니다:

```bash
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/default/secretbox-test | hexdump -C
```

이제, `k8s:enc:secretbox:v1:key1`이라는 prefix가 붙은 암호화 데이터를 볼 수 있습니다:

```bash
ubuntu@cp-1:~$ kubectl create secret generic secretbox-test \
  -n default \
  --from-literal=mykey=mydata
secret/secretbox-test created
ubuntu@cp-1:~$ sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/default/secretbox-test | hexdump -C
00000000  2f 72 65 67 69 73 74 72  79 2f 73 65 63 72 65 74  |/registry/secret|
00000010  73 2f 64 65 66 61 75 6c  74 2f 73 65 63 72 65 74  |s/default/secret|
00000020  62 6f 78 2d 74 65 73 74  0a 6b 38 73 3a 65 6e 63  |box-test.k8s:enc|
00000030  3a 73 65 63 72 65 74 62  6f 78 3a 76 31 3a 6b 65  |:secretbox:v1:ke|
00000040  79 31 3a 27 18 51 db ab  8c 63 f2 58 40 43 48 87  |y1:'.Q...c.X@CH.|
00000050  70 d4 63 a3 57 06 4a 33  96 4c 8a 1a 69 72 16 7f  |p.c.W.J3.L..ir..|
00000060  7f ff fb 91 23 70 55 24  bb 24 58 1d 17 1b 5e dd  |....#pU$.$X...^.|
00000070  57 8c 3a 06 a5 89 7d fc  5e 07 5f 8a eb d8 89 db  |W.:...}.^._.....|
00000080  c9 a9 65 cf 85 fc 78 d8  82 66 07 93 0f 2a 66 1a  |..e...x..f...*f.|
00000090  48 f7 da c9 6e 27 86 64  82 ae c6 81 61 fa 59 e7  |H...n'.d....a.Y.|
000000a0  4b 83 dd b5 e3 5f cc 18  81 be e1 38 1c 5e 61 5c  |K...._.....8.^a\|
000000b0  b2 74 cb 3c 76 ea f5 68  0f 21 c2 d6 8a 14 8a 57  |.t.<v..h.!.....W|
000000c0  4c cd 4b 3c 64 35 b2 2f  5d df c1 88 d8 19 a6 dd  |L.K<d5./].......|
000000d0  e5 3e c5 49 98 6b cc b4  40 81 81 15 38 99 93 70  |.>.I.k..@...8..p|
000000e0  d1 f5 a0 2c 4d 3e c0 9d  b3 45 15 4c 2c 26 da 24  |...,M>...E.L,&.$|
000000f0  5f 36 e2 58 61 01 c3 a5  9d 0e d7 34 11 9b 26 55  |_6.Xa......4..&U|
00000100  56 ff ed 5c 81 bd fb de  25 e8 04 54 28 e8 08 33  |V..\....%..T(..3|
00000110  4a 03 8a ae 5b fc 61 13  49 91 72 90 36 6e 1c 44  |J...[.a.I.r.6n.D|
00000120  8e 01 a4 49 1c 43 2e 43  2d 87 18 26 f1 a2 94 93  |...I.C.C-..&....|
00000130  09 61 dd b4 51 df 46 27  94 a5 7d 53 70 6e b5 3d  |.a..Q.F'..}Spn.=|
00000140  0d c5 40 83 c1 21 f0 74  ac bc cb c1 fe 8a 6f d5  |..@..!.t......o.|
00000150  e9 2d e0 15 59 37 0a                              |.-..Y7.|
00000157
ubuntu@cp-1:~$
```

> [!WARNING] \
> 기존의 데이터들은 암호화가 자동으로 진행되지 않습니다. \
> 대신, `kubectl get secrets -A -o json | kubectl replace -f -`명령어로 기존 시크릿들도 암호화할 수 있습니다.

---

## CLI 도구 모음

- [kubectl 설치](https://kubernetes.io/ko/docs/tasks/tools/#kubectl)
- [kubectx 설치](https://github.com/ahmetb/kubectx)
- [helm 설치](https://helm.sh/docs/intro/install/)
- [argocd cli 설치](https://argo-cd.readthedocs.io/en/stable/cli_installation/)

## 추가예정중인 정보 및 수정할 것들

- 플레이북 개선
- HA Control Plane 구성
- Cilium 세부 설정 안내
