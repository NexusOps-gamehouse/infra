#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 지금 작업할 서비스만 켠다
#
# 관측 배선은 서비스 하나씩 붙인다. 그러니 5개를 동시에 켜둘 이유가 없다.
# Docker Desktop 메모리가 빠듯할 때 가장 효과가 큰 조치다.
#
#   ./scripts/k8s-local-scale.sh work user      # user 만 켜고 나머지는 눕힘
#   ./scripts/k8s-local-scale.sh work user riot # 둘만
#   ./scripts/k8s-local-scale.sh all            # 전부 켬 (E2E 확인용)
#   ./scripts/k8s-local-scale.sh status         # 지금 상태
#
# ⚠️ replicas=0 은 파드만 지운다. Deployment·Service·ServiceMonitor 는 남는다.
#    그래서 Prometheus Targets 에 그 서비스가 DOWN 으로 뜬다. 정상이다.
#    (일부러 눕힌 것과 진짜 죽은 것을 구분하려면 Grafana 에서 시간대를 본다)
#
# postgres / rabbitmq / frontend 는 건드리지 않는다. 다른 서비스가 의존한다.
# ---------------------------------------------------------------------------
set -euo pipefail
NS=gamehouse
ALL=(user post chat match riot)

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
[ $# -ge 1 ] || usage

case "$1" in
  status)
    printf "%-10s %-8s %s\n" "SERVICE" "REPLICAS" "READY"
    for s in "${ALL[@]}"; do
      if kubectl get deploy "$s" -n "$NS" >/dev/null 2>&1; then
        R=$(kubectl get deploy "$s" -n "$NS" -o jsonpath='{.spec.replicas}')
        RD=$(kubectl get deploy "$s" -n "$NS" -o jsonpath='{.status.readyReplicas}')
        printf "%-10s %-8s %s\n" "$s" "$R" "${RD:-0}"
      else
        printf "%-10s %-8s %s\n" "$s" "-" "(없음)"
      fi
    done
    echo
    kubectl top nodes 2>/dev/null || echo "(kubectl top: metrics-server 준비 중)"
    ;;

  all)
    for s in "${ALL[@]}"; do
      kubectl get deploy "$s" -n "$NS" >/dev/null 2>&1 \
        && kubectl -n "$NS" scale deploy "$s" --replicas=1
    done
    echo "▶ 전부 켰다. 메모리가 빠듯하면 Pending 이 뜰 수 있다:"
    echo "   kubectl -n $NS get pods | grep -v Running"
    ;;

  work)
    shift
    [ $# -ge 1 ] || usage
    KEEP=" $* "
    for s in "${ALL[@]}"; do
      kubectl get deploy "$s" -n "$NS" >/dev/null 2>&1 || continue
      if [[ "$KEEP" == *" $s "* ]]; then
        kubectl -n "$NS" scale deploy "$s" --replicas=1
      else
        kubectl -n "$NS" scale deploy "$s" --replicas=0
      fi
    done
    echo
    echo "▶ 켜둔 것:$KEEP"
    echo "  나머지는 replicas=0. Prometheus Targets 에 DOWN 으로 보이는 건 정상이다."
    ;;

  *) usage ;;
esac
