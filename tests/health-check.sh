#!/bin/bash
echo "=== Quick Health Check ==="
echo ""
echo "Flux Controllers:"
kubectl get pods -n flux-system --no-headers | awk '{print $1, $3}'
echo ""
echo "VClusters:"
kubectl get pods -n vcluster-a vcluster-a-0 --no-headers | awk '{print "vcluster-a:", $3}'
kubectl get pods -n vcluster-b vcluster-b-0 --no-headers | awk '{print "vcluster-b:", $3}'
echo ""
echo "Traefik:"
kubectl get pods -n traefik -l app.kubernetes.io/name=traefik --no-headers | awk '{print $1, $3}'
echo ""
echo "HTTP Endpoints:"
TRAEFIK_IP=$(kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -s -o /dev/null -w "tenant-a: %{http_code}\n" -Lk --resolve tenant-a.traefik.local:80:$TRAEFIK_IP --resolve tenant-a.traefik.local:443:$TRAEFIK_IP http://tenant-a.traefik.local
curl -s -o /dev/null -w "tenant-b: %{http_code}\n" -Lk --resolve tenant-b.traefik.local:80:$TRAEFIK_IP --resolve tenant-b.traefik.local:443:$TRAEFIK_IP http://tenant-b.traefik.local
