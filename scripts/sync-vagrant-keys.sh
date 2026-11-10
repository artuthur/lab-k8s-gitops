#!/bin/bash
# Copie les clés privées générées par Vagrant (dossier .vagrant du projet, souvent sur
# un disque Windows monté dans WSL2, ex. /mnt/c ou /mnt/f) vers le système de fichiers
# natif de WSL2, où les permissions Unix fonctionnent réellement : OpenSSH refuse une
# clé privée qui apparaît accessible à tous (777 sur un disque Windows monté).
#
# À relancer après chaque "vagrant destroy" puis "vagrant up" : Vagrant génère une
# nouvelle clé privée par machine.
#
# Chemin des clés propre au provider vmware_desktop :
#   .vagrant/machines/<nom>/vmware_desktop/private_key

set -euo pipefail

# Racine du projet : déduite de l'emplacement de ce script (scripts/..), pour qu'aucun
# chemin propre à une machine ne soit écrit en dur.
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_DIR="$HOME/.ssh/lab-k8s-gitops"

mkdir -p "$DEST_DIR"
chmod 700 "$DEST_DIR"

for host in k8s-cp-01 k8s-worker-01 k8s-worker-02; do
  src="$PROJECT_DIR/.vagrant/machines/$host/vmware_desktop/private_key"
  if [ ! -f "$src" ]; then
    echo "ERREUR - clé introuvable : $src (les VMs ont-elles été créées avec 'vagrant up' ?)" >&2
    exit 1
  fi
  cp "$src" "$DEST_DIR/private_key_$host"
  chmod 600 "$DEST_DIR/private_key_$host"
  echo "Clé copiée pour $host -> $DEST_DIR/private_key_$host"
done
