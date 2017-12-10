#!/bin/bash

setenforce 0

sed -i 's/selinux=enforcing/selinux=disabled/g' /etc/sysconfig/selinux

sudo yum install -y yum-utils \
  device-mapper-persistent-data \
  lvm2

sudo yum-config-manager \
    --add-repo \
    https://download.docker.com/linux/centos/docker-ce.repo

sudo yum-config-manager --enable docker-ce-edge

yum install -y --setopt=obsoletes=0 \
   docker-ce-17.03.0.ce-1.el7.centos.x86_64 \
   docker-ce-selinux-17.03.0.ce-1.el7.centos.noarch # on a new system with yum repo defined, forcing older version and ignoring obsoletes introduced by 17.06.0

yum install epel-release -y

yum install pdsh -y

cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://packages.cloud.google.com/yum/repos/kubernetes-el7-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOF

yum install -y kubelet kubeadm kubectl

# Configurando hostname en todos los equipos y agregando las ip de los equipos en etc hosts con sus nombres
hostname kub01

cat <<EOF >  /etc/hostname
kub01
EOF

# Add ip y nombres de hosts en todos los masters
cat <<EOF >> /etc/hosts
172.31.27.31 kub01
172.31.41.254 kub02
172.31.12.35 kub03
172.31.12.10 kublb01
172.31.12.20 minion1
172.31.12.21 minion2
EOF

## Generando Certificados y editar por las ips de nuestros equipos para etcd | SOLO EN EL KUB01

mkdir -p ~/k8s/crt ~/k8s/key ~/k8s/csr

cat <<__EOF__>~/k8s/openssl.cnf
[ req ]
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_ca ]
basicConstraints = critical, CA:TRUE
keyUsage = critical, digitalSignature, keyEncipherment, keyCertSign
[ v3_req_etcd ]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names_etcd
[ alt_names_etcd ]
DNS.1 = kub01
DNS.2 = kub02
DNS.3 = kub03
DNS.4 = master.itshellws-k8s.com
DNS.5 = cluster.itshellws-k8s.com
DNS.6 = elb.itshellws-k8s.com
IP.1 = 172.31.27.31
IP.2 = 172.31.41.254
IP.3 = 172.31.12.35 
IP.4 = 172.31.12.10
__EOF__

openssl genrsa -out ~/k8s/key/etcd-ca.key 4096
openssl req -x509 -new -sha256 -nodes -key ~/k8s/key/etcd-ca.key -days 3650 -out ~/k8s/crt/etcd-ca.crt -subj "/CN=etcd-ca" -extensions v3_ca -config ~/k8s/openssl.cnf

openssl genrsa -out ~/k8s/key/etcd.key 4096
openssl req -new -sha256 -key ~/k8s/key/etcd.key -subj "/CN=etcd" -out ~/k8s/csr/etcd.csr
openssl x509 -req -in ~/k8s/csr/etcd.csr -sha256 -CA ~/k8s/crt/etcd-ca.crt -CAkey ~/k8s/key/etcd-ca.key -CAcreateserial -out ~/k8s/crt/etcd.crt -days 365 -extensions v3_req_etcd -extfile ~/k8s/openssl.cnf
openssl genrsa -out ~/k8s/key/etcd-peer.key 4096
openssl req -new -sha256 -key ~/k8s/key/etcd-peer.key -subj "/CN=etcd-peer" -out ~/k8s/csr/etcd-peer.csr
openssl x509 -req -in ~/k8s/csr/etcd-peer.csr -sha256 -CA ~/k8s/crt/etcd-ca.crt -CAkey ~/k8s/key/etcd-ca.key -CAcreateserial -out ~/k8s/crt/etcd-peer.crt -days 365 -extensions v3_req_etcd -extfile ~/k8s/openssl.cnf

#Instalar ETCD en todos los nodos Master.

ETCD_VER=v3.2.11
GOOGLE_URL=https://storage.googleapis.com/etcd
GITHUB_URL=https://github.com/coreos/etcd/releases/download
DOWNLOAD_URL=${GOOGLE_URL}
mkdir ~/etcd_${ETCD_VER}
cd ~/etcd_${ETCD_VER}

cat <<__EOF__>etcd_${ETCD_VER}-install.sh
curl -L ${DOWNLOAD_URL}/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz -o etcd-${ETCD_VER}-linux-amd64.tar.gz
tar xzvf etcd-${ETCD_VER}-linux-amd64.tar.gz -C .
__EOF__

chmod +x etcd_${ETCD_VER}-install.sh
./etcd_${ETCD_VER}-install.sh

cat <<__EOF__>~/etcd.service
[Unit]
Description=etcd
Documentation=https://github.com/coreos

[Service]
ExecStart=/usr/bin/etcd \
  --name kub01 \
  --cert-file=/etc/etcd/pki/etcd.crt \
  --key-file=/etc/etcd/pki/etcd.key \
  --peer-cert-file=/etc/etcd/pki/etcd-peer.crt \
  --peer-key-file=/etc/etcd/pki/etcd-peer.key \
  --trusted-ca-file=/etc/etcd/pki/etcd-ca.crt \
  --peer-trusted-ca-file=/etc/etcd/pki/etcd-ca.crt \
  --peer-client-cert-auth \
  --client-cert-auth \
  --initial-advertise-peer-urls https://172.31.27.31:2380 \
  --listen-peer-urls https://172.31.27.31:2380 \
  --listen-client-urls https://172.31.27.31:2379,http://127.0.0.1:2379 \
  --advertise-client-urls https://172.31.27.31:2379 \
  --initial-cluster-token etcd-cluster-0 \
  --initial-cluster kub01=https://172.31.27.31:2380,kub02=https://172.31.41.254:2380,kub03=https://172.31.12.35:2380 \
  --data-dir=/var/lib/etcd
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target

__EOF__

#Generamos una llave privada y publica

cat <<__EOF__>~/.ssh/id_rsa
-----BEGIN RSA PRIVATE KEY-----
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
-----END RSA PRIVATE KEY-----
__EOF__

cat <<__EOF__>~/.ssh/id_rsa.pub
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCuYwSG7KX+5boMDJPO44SCbb5y3NRtlER3bd1+pGO+XuLXW81vcjAjOaD4TunvcYdwxLzmUTu6qN1lpkylY+AL3keUNLiqUSMLsQ0axiZN5KZbjXVft0ck0/zwNvUrRAehrbPfLSp9sni9/EUzvcsvkCAyKbzR4MOYkkqzlSVEkIGfzoMmTDUt+vb4eAFp2eOK3spU/aN8citNcqE2Wm5/kvppQh/5kgtJt3Md/9wUSST4XFaK5xigIq+dPFEfbrSR8yBnYjCVs6Kpg9+A3FCKRUE6nz1t5DwurmhoAH0K1NVjUUQe2p+yCM3ULWPktspNZB4Z5gcuB+iydB5QcSJzSA9HsGKwxOWhy5nEETd6Oh0ZlCzoA4/M10Uv1OpZH/RO40WtcpMe0sfiptQx5AinxoYys1mFYV+NquuBQWjkcKdvuA1cqHjhRJDM7y+j5pW/QT2UGhPGYEpGVA75yUmfDICUghZnHTL93MmDh3xgCgIEXtuloOf447E5IR61kVSr1AdRtEWaKh392NOF+UfSwUz8ILEtH4kLq6RQ6gSpwtb5hJcNR/stkx+4EPiLe02djH1d8k2Hb47HhVxrxW53Qkoq32yI8LPt+6Eca9H96Tl7usCjU5Ai+uhtk+jUWmzHrtPLbdwCGI0m2JGO7fWVa/QTwaUIwSHSDGKz1uVOkw== cluster@k8s.io
__EOF__

# Agregamos llave la llave generada
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_rsa

chmod 0600 ~/.ssh/id_rsa
chmod 0600 ~/.ssh/id_rsa.pub
chmod 0600 ~/.ssh/config

cat <<__EOF__>~/.ssh/config
ServerAliveInterval=100

# kub MASTERS #
Host kub*
  StrictHostKeyChecking no
  User ec2-user
  IdentityFile ~/.ssh/id_rsa

# kub Minion #
Host minion*
  StrictHostKeyChecking no
  User ec2-user
  IdentityFile ~/.ssh/id_rsa

__EOF__

cp ~/.ssh/id_rsa /home/centos/.ssh/
cp ~/.ssh/id_rsa.pub /home/centos/.ssh/
cp ~/.ssh/config /home/centos/.ssh/config

cat <<EOF >> ~/.ssh/authorized_keys
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCuYwSG7KX+5boMDJPO44SCbb5y3NRtlER3bd1+pGO+XuLXW81vcjAjOaD4TunvcYdwxLzmUTu6qN1lpkylY+AL3keUNLiqUSMLsQ0axiZN5KZbjXVft0ck0/zwNvUrRAehrbPfLSp9sni9/EUzvcsvkCAyKbzR4MOYkkqzlSVEkIGfzoMmTDUt+vb4eAFp2eOK3spU/aN8citNcqE2Wm5/kvppQh/5kgtJt3Md/9wUSST4XFaK5xigIq+dPFEfbrSR8yBnYjCVs6Kpg9+A3FCKRUE6nz1t5DwurmhoAH0K1NVjUUQe2p+yCM3ULWPktspNZB4Z5gcuB+iydB5QcSJzSA9HsGKwxOWhy5nEETd6Oh0ZlCzoA4/M10Uv1OpZH/RO40WtcpMe0sfiptQx5AinxoYys1mFYV+NquuBQWjkcKdvuA1cqHjhRJDM7y+j5pW/QT2UGhPGYEpGVA75yUmfDICUghZnHTL93MmDh3xgCgIEXtuloOf447E5IR61kVSr1AdRtEWaKh392NOF+UfSwUz8ILEtH4kLq6RQ6gSpwtb5hJcNR/stkx+4EPiLe02djH1d8k2Hb47HhVxrxW53Qkoq32yI8LPt+6Eca9H96Tl7usCjU5Ai+uhtk+jUWmzHrtPLbdwCGI0m2JGO7fWVa/QTwaUIwSHSDGKz1uVOkw== cluster@k8s.io
EOF

cat <<EOF >> /home/centos/.ssh/authorized_keys
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCuYwSG7KX+5boMDJPO44SCbb5y3NRtlER3bd1+pGO+XuLXW81vcjAjOaD4TunvcYdwxLzmUTu6qN1lpkylY+AL3keUNLiqUSMLsQ0axiZN5KZbjXVft0ck0/zwNvUrRAehrbPfLSp9sni9/EUzvcsvkCAyKbzR4MOYkkqzlSVEkIGfzoMmTDUt+vb4eAFp2eOK3spU/aN8citNcqE2Wm5/kvppQh/5kgtJt3Md/9wUSST4XFaK5xigIq+dPFEfbrSR8yBnYjCVs6Kpg9+A3FCKRUE6nz1t5DwurmhoAH0K1NVjUUQe2p+yCM3ULWPktspNZB4Z5gcuB+iydB5QcSJzSA9HsGKwxOWhy5nEETd6Oh0ZlCzoA4/M10Uv1OpZH/RO40WtcpMe0sfiptQx5AinxoYys1mFYV+NquuBQWjkcKdvuA1cqHjhRJDM7y+j5pW/QT2UGhPGYEpGVA75yUmfDICUghZnHTL93MmDh3xgCgIEXtuloOf447E5IR61kVSr1AdRtEWaKh392NOF+UfSwUz8ILEtH4kLq6RQ6gSpwtb5hJcNR/stkx+4EPiLe02djH1d8k2Hb47HhVxrxW53Qkoq32yI8LPt+6Eca9H96Tl7usCjU5Ai+uhtk+jUWmzHrtPLbdwCGI0m2JGO7fWVa/QTwaUIwSHSDGKz1uVOkw== cluster@k8s.io
EOF

mkdir -p /etc/etcd/pki ; mkdir -p /var/lib/etcd

cd /root
cp ./k8s/crt/etcd* ./k8s/key/etcd* /etc/etcd/pki/
ls /etc/etcd/pki/
cp ~/etcd.service /etc/systemd/system/etcd.service
cp ~/etcd_${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64/etcd* /usr/bin/

cd

systemctl daemon-reload && systemctl start etcd && systemctl restart etcd && systemctl status etcd && systemctl enable etcd

useradd -d /home/kubeadmin -s /bin/bash -G docker,root kubeadmin

cat <<__EOF__>~/kubeadm-init.yaml
apiVersion: kubeadm.k8s.io/v1alpha1
kind: MasterConfiguration
api:
  advertiseAddress: 172.31.27.31
  bindPort: 6443
etcd:
  endpoints:
  - https://172.31.27.31:2379
  - https://172.31.41.254:2379
  - https://172.31.12.35:2379
  caFile: /etc/etcd/pki/etcd-ca.crt
  certFile: /etc/etcd/pki/etcd.crt
  keyFile: /etc/etcd/pki/etcd.key
  dataDir: /var/lib/etcd
networking:
  podSubnet: 10.244.0.0/16
apiServerCertSANs:
- kub01
- kub02
- kub03
- kublb01.home
- kublb01
- master.itshellws-k8s.com
- cluster.itshellws-k8s.com
- elb.itshellws-k8s.com
- 172.31.27.31
- 172.31.41.254
- 172.31.12.35 
- 172.31.12.10
certificatesDir: /etc/kubernetes/pki/
__EOF__

systemctl start docker && systemctl enable docker && systemctl enable kubelet.service

sed -i 's/Environment="KUBELET_CGROUP_ARGS=--cgroup-driver=systemd"/Environment="KUBELET_CGROUP_ARGS=--cgroup-driver=cgroupfs"/g' /etc/systemd/system/kubelet.service.d/10-kubeadm.conf

systemctl daemon-reload && systemctl restart kubelet && systemctl stop kubelet

scp -r k8s/ centos@kub02:/home/centos
scp -r k8s/ centos@kub03:/home/centos
pdsh -l centos -w "kub0[2-3]" "sudo /root/etcd.sh"

systemctl daemon-reload && systemctl start etcd && systemctl restart etcd && systemctl status etcd && systemctl enable etcd

kubeadm init --config ~/kubeadm-init.yaml

rm -rf .kube
mkdir .kube
sudo cp /etc/kubernetes/admin.conf .kube/config
sudo chown $(id -u):$(id -g) .kube/config

sudo systemctl stop kubelet && systemctl stop docker && sudo systemctl status kubelet docker

sed -i 's/--admission-control=Initializers,NamespaceLifecycle,LimitRanger,ServiceAccount,PersistentVolumeLabel,DefaultStorageClass,DefaultTolerationSeconds,NodeRestriction,ResourceQuota/--admission-control=Initializers,NamespaceLifecycle,LimitRanger,ServiceAccount,PersistentVolumeLabel,DefaultStorageClass,DefaultTolerationSeconds,ResourceQuota/g' /etc/kubernetes/manifests/kube-apiserver.yaml

sudo systemctl restart docker && systemctl restart kubelet && systemctl status docker && systemctl status kubelet

rsync -av -e ssh --progress /etc/kubernetes centos@kub02:/home/centos

rsync -av -e ssh --progress /etc/kubernetes centos@kub03:/home/centos

tar -cvf kube.tar .kube/

rsync -av -e ssh --progress kube.tar centos@kub02:/home/centos

rsync -av -e ssh --progress kube.tar centos@kub03:/home/centos

rm -f /etc/cni/net.d/*flannel*

sudo systemctl restart docker && systemctl restart kubelet && systemctl status docker && systemctl status kubelet

sleep 15 

pdsh -l centos -w "kub0[2-3]" "sudo /root/install.sh"

cat <<__EOF__>~/kub01.sh
#!/bin/bash

kubectl patch node kub02 -p '{"metadata":{"labels":{"node-role.kubernetes.io/master":""}},"spec":{"taints":[{"effect":"NoSchedule","key":"node-role.kubernetes.io/master","timeAdded":null}]}}'

kubectl patch node kub03 -p '{"metadata":{"labels":{"node-role.kubernetes.io/master":""}},"spec":{"taints":[{"effect":"NoSchedule","key":"node-role.kubernetes.io/master","timeAdded":null}]}}'

curl -O https://raw.githubusercontent.com/nightmareze1/kubernetes-1.8-ha/master/weave-1.7.yaml

kubectl apply -f weave-1.7.yaml

__EOF__

sleep 30 

chmod 777 ~/install.sh
chmod 777 ~/kub01.sh

systemctl restart sshd

bash ~/kub01.sh



