#!/bin/zsh
if [[ ($1 != 'suspend') && ($1 != 'resume') ]]; then
    echo "$1 whas not correct"
    exit 0
fi;

for i in $(kubectl get kustomizations.kustomize.toolkit.fluxcd.io -n flux-system -o name | cut -d "/" -f2); do
    flux $1 kustomization -n flux-system $i --timeout 1s
done