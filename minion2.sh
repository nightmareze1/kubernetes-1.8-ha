#!/bin/bash
setenforce 0

vi /etc/sysconfig/selinux
selinux=disabled

sudo yum install -y yum-utils \
  device-mapper-persistent-data \
  lvm2

sudo yum-config-manager \
    --add-repo \
    https://download.docker.com/linux/centos/docker-ce.repo

sudo yum-config-manager --enable docker-ce-edge

yum install -y --setopt=obsoletes=0 \
   docker-ce-17.03.0.ce-1.el7.centos.x86_64 \
   docker-ce-selinux-17.03.0.ce-1.el7.centos.noarch

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

hostname minion2

cat <<EOF >  /etc/hostname
minion2
EOF

cat <<EOF >> /etc/hosts
172.31.27.31 kub01
172.31.41.254 kub02
172.31.12.35 kub03
172.31.12.10 kublb01
172.31.12.20 minion1
172.31.12.21 minion2
EOF

# Reemplazamos linea de systemd a cgroupfs

sed -i 's/Environment="KUBELET_CGROUP_ARGS=--cgroup-driver=systemd"/Environment="KUBELET_CGROUP_ARGS=--cgroup-driver=cgroupfs"/g' /etc/systemd/system/kubelet.service.d/10-kubeadm.conf

systemctl daemon-reload && systemctl restart kubelet && systemctl restart docker && systemctl enable docker && systemctl enable kubelet

cat <<__EOF__>~/join.sh
#!/bin/bash

kubeadm join --token <TOKEN> 172.31.12.10:6443 --discovery-token-ca-cert-hash sha256:<hash GENERADO>

cat <<EOF >> /etc/fstab
fs-db4df172.efs.us-west-2.amazonaws.com:/ /efs nfs4 nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,_netdev 0 0
EOF

__EOF__

chmod 777 ~/join.sh



