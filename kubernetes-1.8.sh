# Instalar paquetes en todos los equipos

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
   docker-ce-selinux-17.03.0.ce-1.el7.centos.noarch # on a new system with yum repo defined, forcing older version and ignoring obsoletes introduced by 17.06.0

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

vi /etc/hostname
kub01

# Add ip y nombres de hosts en todos los masters
vi /etc/hosts
172.30.0.161 kub01
172.30.1.43 kub02
172.30.2.69 kub03
172.30.0.28 kublb01
172.30.0.31 minion1

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
IP.1 = 172.30.0.161
IP.2 = 172.30.1.43
IP.3 = 172.30.2.69 
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

ETCD_VER=v3.2.9
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

# Create Daemon etcd.service y Configurar las ips y nombres correctamente | Ejecutar en cada 1 de los nodos el q corresponde

· kub01 - Solo lo vamos a crear en el kub01 al final lo vamos a crear para los demas

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
  --initial-advertise-peer-urls https://172.30.0.161:2380 \
  --listen-peer-urls https://172.30.0.161:2380 \
  --listen-client-urls https://172.30.0.161:2379,http://127.0.0.1:2379 \
  --advertise-client-urls https://172.30.0.161:2379 \
  --initial-cluster-token etcd-cluster-0 \
  --initial-cluster kub01=https://172.30.0.161:2380,kub02=https://172.30.1.43:2380,kub03=https://172.30.2.69:2380 \
  --data-dir=/var/lib/etcd
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target

__EOF__


# En todos los Nodos Master

mkdir -p /etc/etcd/pki ; mkdir -p /var/lib/etcd


#Generamos clave ssh y configuramos el acceso en todos los nodos
ssh-keygen -t rsa -b 4096 -C "cluster@k8s.io"

# Veremos algo asi y le pegamos todo ENTER
Generating public/private rsa key pair.
Enter a file in which to save the key (/home/you/.ssh/id_rsa): [Press enter]
Enter passphrase (empty for no passphrase): [Type a passphrase]
Enter same passphrase again: [Type passphrase again]

# Agregamos la ssh key a nuestro repo de llaves
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_rsa

# Luego copiamos el valor de la llave privada en autorized Keys
cat  ~/.ssh/id_rsa.pub

ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCnjbsZA5BZ1wjHCPjNV6/QmPWQmWciw4sWak3KkrbsU9LiqVBCHFz9kf7mOPZAFJz/pXNWNK0HAeMPjZwfFMQ5GvpCcxDdcgfZRfBhqKB2/8PEpVN9a9a+PKmhbD+PGs3adWYJdK1cStuEE+nyQYA2VKjonif4QDnwe8F46wFZGO5pfPIGCX4V++BH9x+DYOIq5OMAUwChiu6wfmlnQ/LPM4KJ2tqQLhp5QPo1/vYhjsWKaPS2tATOzdXuN+h+IdQsplwJss/aaxAuW/yr5XdnXi4aEd/RYrAg2my4rFIWukQ9MStcRal8JiSrv8yCGkLWluVpsh5A9tm/MhfJFD3ABnJLMVTDOvmFB1MUmH9V9VOpNHsSH7yRqCkZFomFFSrpqa5H14hbcZekM5/I66mmojhMbdxk7TqOuQgmMO/uPGGYnT55Ii07Lx4gAN+vfjuktFuJIWVDC2GayWJWXQ4baNRzvtFAcSvTabJJuXjajFIbAmn1B4yeYwycSt6VnJ16ChXugZNa6W3/6SLyWPKLvUz9lWQWI3TCUu8eRvL/oPKEDY+MYDPTaETexFrAGU8zsQm9vV+tBRvHFKDpZJfEXd7VhMlFFKYEtN9pWURur3na3PXKx3bktDxADJsi6YjjbHkeuYv1tQYslU2jDQ2RAVrPFaoccxbcPxk8XGH/YQ== cluster@k8s.io


# Agregamos la llave en todos los nodos 
vi  ~/.ssh/authorized_keys

ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCnjbsZA5BZ1wjHCPjNV6/QmPWQmWciw4sWak3KkrbsU9LiqVBCHFz9kf7mOPZAFJz/pXNWNK0HAeMPjZwfFMQ5GvpCcxDdcgfZRfBhqKB2/8PEpVN9a9a+PKmhbD+PGs3adWYJdK1cStuEE+nyQYA2VKjonif4QDnwe8F46wFZGO5pfPIGCX4V++BH9x+DYOIq5OMAUwChiu6wfmlnQ/LPM4KJ2tqQLhp5QPo1/vYhjsWKaPS2tATOzdXuN+h+IdQsplwJss/aaxAuW/yr5XdnXi4aEd/RYrAg2my4rFIWukQ9MStcRal8JiSrv8yCGkLWluVpsh5A9tm/MhfJFD3ABnJLMVTDOvmFB1MUmH9V9VOpNHsSH7yRqCkZFomFFSrpqa5H14hbcZekM5/I66mmojhMbdxk7TqOuQgmMO/uPGGYnT55Ii07Lx4gAN+vfjuktFuJIWVDC2GayWJWXQ4baNRzvtFAcSvTabJJuXjajFIbAmn1B4yeYwycSt6VnJ16ChXugZNa6W3/6SLyWPKLvUz9lWQWI3TCUu8eRvL/oPKEDY+MYDPTaETexFrAGU8zsQm9vV+tBRvHFKDpZJfEXd7VhMlFFKYEtN9pWURur3na3PXKx3bktDxADJsi6YjjbHkeuYv1tQYslU2jDQ2RAVrPFaoccxbcPxk8XGH/YQ== cluster@k8s.io

NOTA : Debemos agregar el acceso ssh, tanto para el usuario "centos" como "root"

#Copiamos Los certificados y el demonio en los otros servidores

cd
scp -r k8s/ centos@kub02:/home/centos
scp etcd.service centos@kub02:/home/centos/
scp etcd_v3.2.9/etcd-v3.2.9-linux-amd64/etcd* centos@kub02:/home/centos/

scp -r k8s/ centos@kub03:/home/centos
scp etcd.service centos@kub03:/home/centos/
scp etcd_v3.2.9/etcd-v3.2.9-linux-amd64/etcd* centos@kub03:/home/centos/

# Una vez que tenemos todo copiado lo movemos a la ubicacion correspondiente

mkdir -p /etc/etcd/pki ; mkdir -p /var/lib/etcd

cd /home/centos #Desde los nodos kub02 y kub03

cp ./k8s/crt/etcd* ./k8s/key/etcd* /etc/etcd/pki/
ls /etc/etcd/pki/
cp etcd.service /etc/systemd/system/etcd.service
cp etcd /usr/bin/
cp etcdctl /usr/bin/

# Creamos los demons para kub02 y kub03

· kub02

cat <<__EOF__>~/etcd.service
[Unit]
Description=etcd
Documentation=https://github.com/coreos

[Service]
ExecStart=/usr/bin/etcd \
  --name kub02 \
  --cert-file=/etc/etcd/pki/etcd.crt \
  --key-file=/etc/etcd/pki/etcd.key \
  --peer-cert-file=/etc/etcd/pki/etcd-peer.crt \
  --peer-key-file=/etc/etcd/pki/etcd-peer.key \
  --trusted-ca-file=/etc/etcd/pki/etcd-ca.crt \
  --peer-trusted-ca-file=/etc/etcd/pki/etcd-ca.crt \
  --peer-client-cert-auth \
  --client-cert-auth \
  --initial-advertise-peer-urls https://172.30.1.43:2380 \
  --listen-peer-urls https://172.30.1.43:2380 \
  --listen-client-urls https://172.30.1.43:2379,http://127.0.0.1:2379 \
  --advertise-client-urls https://172.30.1.43:2379 \
  --initial-cluster-token etcd-cluster-0 \
  --initial-cluster kub01=https://172.30.0.161:2380,kub02=https://172.30.1.43:2380,kub03=https://172.30.2.69:2380 \
  --data-dir=/var/lib/etcd
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target

__EOF__

cp ~/etcd.service /etc/systemd/system/etcd.service

· kub03

cat <<__EOF__>~/etcd.service
[Unit]
Description=etcd
Documentation=https://github.com/coreos

[Service]
ExecStart=/usr/bin/etcd \
  --name kub03 \
  --cert-file=/etc/etcd/pki/etcd.crt \
  --key-file=/etc/etcd/pki/etcd.key \
  --peer-cert-file=/etc/etcd/pki/etcd-peer.crt \
  --peer-key-file=/etc/etcd/pki/etcd-peer.key \
  --trusted-ca-file=/etc/etcd/pki/etcd-ca.crt \
  --peer-trusted-ca-file=/etc/etcd/pki/etcd-ca.crt \
  --peer-client-cert-auth \
  --client-cert-auth \
  --initial-advertise-peer-urls https://172.30.2.69:2380 \
  --listen-peer-urls https://172.30.2.69:2380 \
  --listen-client-urls https://172.30.2.69:2379,http://127.0.0.1:2379 \
  --advertise-client-urls https://172.30.2.69:2379 \
  --initial-cluster-token etcd-cluster-0 \
  --initial-cluster kub01=https://172.30.0.161:2380,kub02=https://172.30.1.43:2380,kub03=https://172.30.2.69:2380 \
  --data-dir=/var/lib/etcd
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target

__EOF__

cp ~/etcd.service /etc/systemd/system/etcd.service
cp /home/centos/etcd /usr/bin/etcd
cp /home/centos/etcdctl /usr/bin/etcdctl

# Reiniciamos el demon en todos los nodos
systemctl daemon-reload && systemctl start etcd && systemctl restart etcd && systemctl status etcd && systemctl enable etcd

# Comprobamos estados de cluster etcd

etcdctl --ca-file /etc/etcd/pki/etcd-ca.crt --cert-file /etc/etcd/pki/etcd.crt --key-file /etc/etcd/pki/etcd.key cluster-health

# Comprobamos que rol tiene cada miembro

etcdctl --ca-file /etc/etcd/pki/etcd-ca.crt --cert-file /etc/etcd/pki/etcd.crt --key-file /etc/etcd/pki/etcd.key member list

# Procedemos a crear kubeadm solo en el kub01

useradd -d /home/kubeadmin -s /bin/bash -G docker,root kubeadmin

cat <<__EOF__>~/kubeadm-init.yaml
apiVersion: kubeadm.k8s.io/v1alpha1
kind: MasterConfiguration
api:
  advertiseAddress: 172.30.0.161
  bindPort: 6443
etcd:
  endpoints:
  - https://172.30.0.161:2379
  - https://172.30.1.43:2379
  - https://172.30.2.69:2379
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
- 172.30.0.161
- 172.30.1.43
- 172.30.2.69 
- 172.30.0.28
certificatesDir: /etc/kubernetes/pki/
__EOF__

# Iniciamos los demonios de docker y lo habilitamos | el de kubelet no es necesario se activa al correr kubeadm
systemctl start docker && systemctl enable docker && systemctl enable kubelet.service

#Editamos el siguiente file en todos los nodos
vi /etc/systemd/system/kubelet.service.d/10-kubeadm.conf

Environment="KUBELET_CGROUP_ARGS=--cgroup-driver=cgroupfs"

# Reiniciamos los valores del demon y lo dejamos apagado es un requisito para el kub01
systemctl daemon-reload && systemctl restart kubelet && systemctl stop kubelet

# Y llego el momento de instalar kubernetes solo desde kub01

kubeadm init --config ~/kubeadm-init.yaml #guardamos el initial-cluster-token Generando

kubeadm join --token fe023f.b10eff12f7a05667 172.30.0.161:6443 --discovery-token-ca-cert-hash sha256:c0c3700dd55826c4ce8a61949a79c45a24bc6812b0d2a28f4d7cef80a666f443

# Configuramos el demon de kubectl en nuestro equipo.

rm -rf .kube
mkdir .kube
sudo cp /etc/kubernetes/admin.conf .kube/config
sudo chown $(id -u):$(id -g) .kube/config

# Instalamos el networking.

# Delete route cni and flannel
rm -f /etc/cni/net.d/*flannel*
kubectl apply -f https://github.com/weaveworks/weave/blob/master/prog/weave-kube/weave-daemonset-k8s-1.7.yaml

# CALICO
kubectl apply -f https://docs.projectcalico.org/v2.6/getting-started/kubernetes/installation/hosted/kubeadm/1.6/calico.yaml



# kubectl get nodes
Veremos nuestro nodo preparado

NAME      STATUS    ROLES     AGE       VERSION
kub01     Ready     master    8m        v1.8.4

# Detenemos el demonio de docker y kubernetes

sudo systemctl stop kubelet && systemctl stop docker && sudo systemctl status kubelet docker

# Vamos a configurar el registro de nodos

vi /etc/kubernetes/manifests/kube-apiserver.yaml

# Change in line 32
--admission-control=Initializers,NamespaceLifecycle,LimitRanger,ServiceAccount,PersistentVolumeLabel,DefaultStorageClass,DefaultTolerationSeconds,NodeRestriction,ResourceQuota

# Change this to:
--admission-control=Initializers,NamespaceLifecycle,LimitRanger,ServiceAccount,PersistentVolumeLabel,DefaultStorageClass,DefaultTolerationSeconds,ResourceQuota

# Reiniciamos el demonio de docker y kubelet

sudo systemctl restart docker && systemctl restart kubelet && systemctl status docker && systemctl status kubelet

# Instalacion de Minion o Nodo del cluster

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
   docker-ce-selinux-17.03.0.ce-1.el7.centos.noarch # on a new system with yum repo defined, forcing older version and ignoring obsoletes introduced by 17.06.0

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

# Configuramos el hostname
hostname minion1

vi /etc/hostname
minion1

# Agregamos las ip de nuestros cluster y hostname en el hosts(para resolver sin dns)
vi /etc/hosts
172.30.0.161 kub01
172.30.1.43 kub02
172.30.2.69 kub03
172.30.0.28 kublb01
172.30.0.31 minion1

# IMPORTANTE modificamos la siguientes lineas en el archivo 10-kubeadm.conf

vi /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
modificamos la linea CGROUP_ARGS por 

Environment="KUBELET_CGROUP_ARGS=--cgroup-driver=cgroupfs"

# SOLO PARA FLANNEL CALICO NO ES NECESARIO - Borramos la linea KUBELET_NETWORK_ARGS

# Reiniciamos los demos

systemctl daemon-reload && systemctl restart kubelet && systemctl restart docker && systemctl enable docker && systemctl enable kubelet

# Levantamos un minion y lo joineamos al cluster 

kubeadm join --token fe023f.b10eff12f7a05667 172.30.0.161:6443 --discovery-token-ca-cert-hash sha256:c0c3700dd55826c4ce8a61949a79c45a24bc6812b0d2a28f4d7cef80a666f443

LISTO!! ya podemos probar nuestro cluster

# desde el master levantamos una imagen para probar
kubectl run nginx --image=nginx:alpine

# Si todo salio bien deberiamos ver algo como esto.
[root@kub01 ~]# kubectl get po --all-namespaces
NAMESPACE     NAME                            READY     STATUS    RESTARTS   AGE
default       nginx-f9dbfd4bc-6dfj2           1/1       Running   1          26m
kube-system   kube-apiserver-kub01            1/1       Running   0          39m
kube-system   kube-controller-manager-kub01   1/1       Running   1          1h
kube-system   kube-dns-545bc4bfd4-t5n4w       3/3       Running   3          1h
kube-system   kube-proxy-dggsk                1/1       Running   1          1h
kube-system   kube-proxy-rjnpm                1/1       Running   2          26m
kube-system   kube-scheduler-kub01            1/1       Running   1          1h
kube-system   weave-net-28s7p                 2/2       Running   4          26m
kube-system   weave-net-vsr6j                 2/2       Running   4          55m

## Levantamos el dashboard

kubectl create -f https://raw.githubusercontent.com/kubernetes/dashboard/master/src/deploy/recommended/kubernetes-dashboard.yaml

## COMANDOS PARA GENERARNUEVAMENTE EL TOKEN EN CASO DE Q SE HAYA PERDIDO.
##Generar nuevamente hash desde master

sudo openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der | openssl dgst -sha256 -hex

## Generar nuevamente tocket en master

sudo kubeadm token create --groups system:bootstrappers:kubeadm:default-node-token

# Listar token | Estos vencen a las 24 hs al menos q cambiemos el TTL
sudo kubeadm token list


# copiar data del kub01 a los masters 2 y 3

ssh root@kub01

for master in kub02 kub03; do \
rsync -av -e ssh --progress /etc/kubernetes ${master}:/home/centos ; \
done

# ingresamos a los master 2 y 3 | se debe ejecutar en los 2 servidores.
cd /home/centos
rm -rf /etc/kubernetes

mv kubernetes/ /etc/

vi /etc/systemd/system/kubelet.service.d/10-kubeadm.conf

cd /etc/kubernetes && \
MY_IP=$(hostname -I |awk '{print $1}') && \
MY_HOSTNAME=$(hostname -s) && \
echo ${MY_IP} && \
echo ${MY_HOSTNAME} && \
sed -i.bak "s/kub01/${MY_HOSTNAME}/g" /etc/kubernetes/*.conf && \
sed -i.bak "s/172.31.33.70/${MY_IP}/g" /etc/kubernetes/*.conf && \
sed -i.bak "s/advertise-address=172.31.33.70/advertise-address=${MY_IP}/g" /etc/kubernetes/manifests/kube-apiserver.yaml && \
systemctl daemon-reload && \
systemctl restart docker && \
systemctl restart kubelet 

#Marcarlos como master con el api | el pacht se aplica al nombre FQDN del minion q esta dentro del cluster

kubectl patch node kub02 -p '{"metadata":{"labels":{"node-role.kubernetes.io/master":""}},"spec":{"taints":[{"effect":"NoSchedule","key":"node-role.kubernetes.io/master","timeAdded":null}]}}'

kubectl patch node kub03 -p '{"metadata":{"labels":{"node-role.kubernetes.io/master":""}},"spec":{"taints":[{"effect":"NoSchedule","key":"node-role.kubernetes.io/master","timeAdded":null}]}}'


#REEMPLAZAMOS EN LOS SIGUIENTES FILE LA IP DE KUB01 por la del HOST CORRSEPONDIENTE

[root@kub03 kubernetes]# vi /etc/kubernetes/manifests/kube-apiserver.yaml
[root@kub03 kubernetes]# vi /etc/kubernetes/kubelet.conf
[root@kub03 kubernetes]# vi /etc/kubernetes/admin.conf
[root@kub03 kubernetes]# vi /etc/kubernetes/controller-manager.conf
[root@kub03 kubernetes]# vi /etc/kubernetes/scheduler.conf
[root@kub03 kubernetes]# systemctl daemon-reload && systemctl restart docker kubelet
[root@kub03 kubernetes]# 


# Instalamos el LB

vi /etc/hosts

172.30.0.161 kub01
172.30.1.43 kub02
172.30.2.69 kub03
172.30.0.28 kublb01
172.30.0.31 minion1

hostname kublb01

apt-get update
apt-get install nginx nginx-extras

cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak

cat <<__EOF__>/etc/nginx/nginx.conf
worker_processes  1;
include /etc/nginx/modules-enabled/*.conf;
error_log  /var/log/nginx/error.log warn;
pid        /var/run/nginx.pid;


events {
    worker_connections  1024;
}


http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;

    sendfile        on;
    #tcp_nopush     on;

    keepalive_timeout  65;

    #gzip  on;

    include /etc/nginx/conf.d/*.conf;
}
stream {
        upstream apiserver {
            server 172.30.0.161:6443 weight=5 max_fails=3 fail_timeout=30s;
            server 172.30.1.43:6443 weight=5 max_fails=3 fail_timeout=30s;
            server 172.30.2.69:6443 weight=5 max_fails=3 fail_timeout=30s;
            #server ${HOST_IP}:6443 weight=5 max_fails=3 fail_timeout=30s;
            #server ${HOST_IP}:6443 weight=5 max_fails=3 fail_timeout=30s;
        }

    server {
        listen 6443;
        proxy_connect_timeout 1s;
        proxy_timeout 3s;
        proxy_pass apiserver;
    }
}
__EOF__

systemctl restart nginx && systemctl status nginx

make sure to update the IPs in the config to match your env.

Update the kube-proxy config so that requests go thorugh your lb:

kubectl edit configmap kube-proxy -nkube-system
look for the line starting with “server:” and update the IP/hostname to match your lb. save the file once done.

Verify communication:

On each master:

kubectl get pods --all-namespaces -owide