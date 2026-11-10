#!/bin/bash
# Vérifie le lab de bout en bout, depuis WSL2 : nœuds, réseau des pods, MetalLB,
# Gateway, Argo CD, applications synchronisées sur le dernier commit du dépôt, et
# réponse HTTP de chaque route publiée sur la Gateway.
#
# Usage : ./scripts/verifier-lab.sh [délai maximal en secondes, 600 par défaut]
#
# Juste après une reconstruction, certaines vérifications ne deviennent vraies
# qu'au bout de quelques minutes (Argo CD synchronise les applications après la fin
# du playbook) : chaque vérification est retentée toutes les 5 secondes, jusqu'au
# délai. « ./scripts/verifier-lab.sh 0 » fait un seul essai de chaque.
#
# Code de retour : 0 si tout est bon, 1 sinon.
# Prérequis : kubectl et le kubeconfig du lab (chargés par direnv dans ce dossier).

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VARS="$PROJECT_DIR/inventory/group_vars/all/vars.yml"
INVENTAIRE="$PROJECT_DIR/inventory/hosts.ini"

DELAI="${1:-600}"
FIN=$((SECONDS + DELAI))
ECHECS=0

# Lit une variable simple de vars.yml (« nom: valeur », guillemets facultatifs)
lire_variable() {
  sed -n "s/^$1: *\"\{0,1\}\([^\"]*\)\"\{0,1\} *$/\1/p" "$VARS"
}

ADRESSE_GATEWAY="$(lire_variable k8s_gateway_address)"
DEPOT="$(lire_variable k8s_gitops_repo_url)"
BRANCHE="$(lire_variable k8s_gitops_revision)"

# verifier "description" fonction [arguments...]
# La fonction affiche un détail et renvoie 0 si la vérification passe ; sinon, elle
# affiche la raison et renvoie 1. Elle est retentée jusqu'à la fin du délai.
verifier() {
  local description="$1"
  shift
  local sortie
  while true; do
    if sortie="$("$@" 2>&1)"; then
      printf '  OK     %s : %s\n' "$description" "$sortie"
      return 0
    fi
    if ((SECONDS >= FIN)); then
      printf '  ÉCHEC  %s : %s\n' "$description" "$sortie"
      ECHECS=$((ECHECS + 1))
      return 0
    fi
    sleep 5
  done
}

# --- Les vérifications ---------------------------------------------------------------

api_joignable() {
  kubectl version -o json >/dev/null || return 1
  kubectl config current-context
}

noeuds_prets() {
  local attendus prets
  attendus="$(grep -cE '^k8s-[a-z0-9-]+ ' "$INVENTAIRE")"
  prets="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | grep -c '^True$' || true)"
  if [[ "$prets" != "$attendus" ]]; then
    echo "$prets nœud(s) Ready sur $attendus"
    return 1
  fi
  echo "$prets/$attendus Ready"
}

calico_disponible() {
  local etat
  etat="$(kubectl get tigerastatus calico -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')"
  [[ "$etat" == "True" ]] || { echo "tigerastatus calico : Available=${etat:-inconnu}"; return 1; }
  echo "tigerastatus Available"
}

# Tous les Deployments, StatefulSets et DaemonSets d'un namespace sont-ils prêts ?
namespace_pret() {
  local ns="$1" lignes non_prets total
  lignes="$(
    kubectl -n "$ns" get deployments,statefulsets -o jsonpath='{range .items[*]}{.kind}/{.metadata.name};{.status.readyReplicas};{.spec.replicas}{"\n"}{end}'
    kubectl -n "$ns" get daemonsets -o jsonpath='{range .items[*]}{.kind}/{.metadata.name};{.status.numberReady};{.status.desiredNumberScheduled}{"\n"}{end}'
  )" || return 1
  total="$(grep -c . <<<"$lignes" || true)"
  ((total > 0)) || { echo "aucun composant dans $ns"; return 1; }
  # Séparateur « ; » : un champ vide (0 copie prête n'est pas écrit) reste à sa place
  non_prets="$(awk -F';' '{ prets = ($2 == "" ? 0 : $2) } prets != $3 { printf "%s (%s/%s) ", $1, prets, $3 }' <<<"$lignes")"
  [[ -z "$non_prets" ]] || { echo "pas prêts : $non_prets"; return 1; }
  echo "$total composant(s) prêt(s)"
}

gateway_operationnelle() {
  local programmee adresse
  programmee="$(kubectl -n gateway get gateway lab-gateway -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}')" || return 1
  adresse="$(kubectl -n gateway get gateway lab-gateway -o jsonpath='{.status.addresses[*].value}')"
  [[ "$programmee" == "True" ]] || { echo "Programmed=${programmee:-inconnu}"; return 1; }
  [[ "$adresse" == "$ADRESSE_GATEWAY" ]] || { echo "adresse ${adresse:-aucune} au lieu de $ADRESSE_GATEWAY"; return 1; }
  echo "Programmed, $adresse"
}

applications_synchronisees() {
  local lignes en_defaut
  lignes="$(kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name};{.status.sync.status};{.status.health.status}{"\n"}{end}')" || return 1
  [[ -n "$lignes" ]] || { echo "aucune application"; return 1; }
  en_defaut="$(awk -F';' '$2 != "Synced" || $3 != "Healthy" { printf "%s (%s, %s) ", $1, ($2 == "" ? "?" : $2), ($3 == "" ? "?" : $3) }' <<<"$lignes")"
  [[ -z "$en_defaut" ]] || { echo "$en_defaut"; return 1; }
  echo "$(awk -F';' '{ printf "%s ", $1 }' <<<"$lignes")(Synced, Healthy)"
}

# Les applications appliquent-elles le dernier commit de la branche, sur GitHub ?
dernier_commit_applique() {
  local distant revisions
  distant="$(git ls-remote "$DEPOT" "refs/heads/$BRANCHE" | cut -f1)" || return 1
  [[ -n "$distant" ]] || { echo "branche $BRANCHE introuvable sur $DEPOT"; return 1; }
  revisions="$(kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.status.sync.revision}{"\n"}{end}' | sort -u)"
  [[ "$revisions" == "$distant" ]] || { echo "appliqué : ${revisions:0:7}, dernier commit : ${distant:0:7}"; return 1; }
  echo "${distant:0:7}, $BRANCHE sur GitHub"
}

# Une route répond-elle par la Gateway ? Une réponse 2xx ou 3xx est attendue.
route_repond() {
  local nom="$1" code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --resolve "$nom:80:$ADRESSE_GATEWAY" "http://$nom/")" || true
  [[ "$code" != "000" ]] || { echo "aucune réponse (adresse, ARP ou proxys Envoy)"; return 1; }
  [[ "$code" =~ ^[23] ]] || { echo "HTTP $code"; return 1; }
  echo "HTTP $code"
}

# --- Déroulé -------------------------------------------------------------------------

echo "Vérification du lab ($(date +%T), délai maximal : ${DELAI} s)"

verifier "API server joignable" api_joignable
verifier "Nœuds prêts" noeuds_prets
verifier "Réseau des pods (Calico)" calico_disponible
verifier "DNS du cluster et kube-proxy (kube-system)" namespace_pret kube-system
verifier "MetalLB (metallb-system)" namespace_pret metallb-system
verifier "Envoy Gateway (envoy-gateway-system)" namespace_pret envoy-gateway-system
verifier "Gateway lab-gateway" gateway_operationnelle
verifier "Argo CD (argocd)" namespace_pret argocd
verifier "Applications d'Argo CD" applications_synchronisees
verifier "Dernier commit appliqué" dernier_commit_applique

# Toutes les routes publiées sur la Gateway, quel que soit leur namespace
routes="$(kubectl get httproutes -A -o jsonpath='{range .items[*]}{range .spec.hostnames[*]}{@}{"\n"}{end}{end}' 2>/dev/null | sort -u || true)"
if [[ -z "$routes" ]]; then
  printf '  ÉCHEC  %s : %s\n' "Routes HTTP" "aucune HTTPRoute trouvée"
  ECHECS=$((ECHECS + 1))
else
  while read -r nom; do
    verifier "Route http://$nom" route_repond "$nom"
  done <<<"$routes"
fi

echo
if ((ECHECS == 0)); then
  echo "Tout est opérationnel à $(date +%T) (vérifié en ${SECONDS} s)."
else
  echo "$ECHECS vérification(s) en échec à $(date +%T)."
  exit 1
fi
