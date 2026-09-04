# images: 블록에서 지정한 논리 이름의 newTag 한 줄만 바꾼다.
#
#   awk -v SVC=gamehouse-crew -v TAG=dev-<sha> -f set-image-tag.awk kustomization.yaml
#
# yq 를 쓰지 않는 이유: yq 는 파일을 자기 이미터로 다시 뽑아내면서 빈 줄을
# 전부 지운다(주석과 순서는 지킨다). 태그 한 줄 교체가 7줄 diff 가 되고,
# 매 배포마다 커밋이 쌓이는 파일이라 이력이 읽기 어려워진다.
# kustomize edit set image 는 더 나쁘다 — 파일 전체를 재작성해서 주석이
# 원래 앵커에서 떨어져 엉뚱한 항목을 설명하게 된다.
#
# 대상 항목을 못 찾으면 exit 1. 조용히 아무것도 안 하는 것보다 낫다.
# 편집 결과는 호출하는 쪽에서 yq 로 값을 되읽어 확인한다.

BEGIN { inimg = 0; hit = 0; done = 0 }

# images: 블록 진입
/^images:/ { inimg = 1; print; next }

# 들여쓰기 없는 키가 나오면 블록 종료 (labels:, patches: 등)
inimg && /^[a-zA-Z]/ { inimg = 0 }

# 리스트 항목의 name: 을 만나면 대상인지 판정한다
inimg && /^[[:space:]]*-[[:space:]]*name:[[:space:]]*/ {
  n = $0
  sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "", n)
  gsub(/[[:space:]]+$/, "", n)
  hit = (n == SVC)
}

# 대상 항목 안의 newTag: 만 교체한다. 들여쓰기는 원래 줄에서 그대로 가져온다.
inimg && hit && /^[[:space:]]*newTag:/ {
  match($0, /^[[:space:]]*/)
  ind = substr($0, 1, RLENGTH)
  print ind "newTag: " TAG
  hit = 0
  done = 1
  next
}

{ print }

END {
  if (!done) {
    print "images: 블록에 " SVC " 의 newTag 항목이 없다" > "/dev/stderr"
    exit 1
  }
}
