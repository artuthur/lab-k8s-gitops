Vagrant.configure("2") do |config|

  # Même box que lab-cicd-pipeline : multi-provider, fonctionne avec vmware_desktop.
  config.vm.box = "generic/debian12"

  # Nœuds du cluster. Le nom sert à la fois d'identifiant Vagrant, de nom d'hôte
  # Linux et de nom d'hôte Ansible : Kubernetes enregistre chaque nœud sous son
  # nom d'hôte, autant qu'il soit identique partout.
  #
  # Réseau privé 192.168.58.0/24 : distinct de lab-cicd-pipeline (192.168.57.0/24)
  # et des plages internes du cluster (pods 10.244.0.0/16, services 10.96.0.0/12).
  nodes = [
    { name: "k8s-cp-01",     ip: "192.168.58.10", cpus: 2, memory: 4096 },
    { name: "k8s-worker-01", ip: "192.168.58.11", cpus: 2, memory: 4096 },
    { name: "k8s-worker-02", ip: "192.168.58.12", cpus: 2, memory: 4096 },
  ]

  # Configuration de l'interface du réseau privé (eth1) dans Debian.
  #
  # Vagrant ne la configure pas lui-même (auto_config: false) : à chaque démarrage
  # d'une VM existante (vagrant reload, vagrant up après un halt), il désactive puis
  # réactive eth1, et sa connexion SSH est coupée entre les deux, laissant eth1 éteinte
  # (voir le journal de bord du README, 27/10/2026).
  #
  # La configuration est écrite une seule fois, au premier vagrant up (un provisioner
  # ne se relance pas au reload), dans un fichier que Debian lit à chaque démarrage.
  # Elle ne peut pas être confiée à Ansible : Ansible joint les nœuds par cette adresse.
  configure_private_network = <<-SHELL
    set -eu
    IP="$1"

    # Retire un éventuel bloc écrit par Vagrant (VM créée avec l'ancienne configuration)
    sed -i '/^#VAGRANT-BEGIN/,/^#VAGRANT-END/d' /etc/network/interfaces

    # /etc/network/interfaces contient "source /etc/network/interfaces.d/*"
    cat > /etc/network/interfaces.d/eth1 <<EOF
auto eth1
iface eth1 inet static
    address ${IP}/24
EOF

    # Active l'interface tout de suite (sans effet si elle l'est déjà)
    ifup eth1
  SHELL

  nodes.each do |node|
    config.vm.define node[:name] do |machine|
      machine.vm.hostname = node[:name]
      machine.vm.network "private_network", ip: node[:ip], auto_config: false
      machine.vm.provision "shell", name: "reseau-prive",
        inline: configure_private_network, args: [node[:ip]]
      machine.vm.provider "vmware_desktop" do |v|
        v.gui = false
        v.vmx["memsize"] = node[:memory].to_s
        v.vmx["numvcpus"] = node[:cpus].to_s
      end
    end
  end

end