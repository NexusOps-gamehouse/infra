# CD 파이프라인 시크릿 전달 방식 개선 요청

**작성일** 2026-08-04
**대상** 인프라/보안 담당
**관련 파일**
`backend/.github/workflows/ci-cd.yml`, `frontend/.github/workflows/ci-cd.yml`,
`infra/.github/workflows/ci-cd.yml` — 각 `deploy` job

---

## 1. 요약

배포 시 `.env` 전체를 **SSM `send-command` 의 명령어 문자열 안에 인라인으로** 실어 보내고 있습니다.
그 결과 DB 비밀번호, JWT 서명키, Riot API 키, RabbitMQ 계정, Grafana admin 비밀번호가
**AWS 측 명령 이력에 사실상 평문으로 보존**됩니다.

애플리케이션 동작에는 문제가 없어 급한 장애는 아니지만,
자격증명이 로그 저장소에 축적되는 구조라 시간이 갈수록 회수 비용이 커집니다.

---

## 2. 현재 구현

```yaml
- name: Encode ENV_FILE
  run: |
    printf "%s" "${{ secrets.ENV_FILE }}" | base64 -w0 > env.b64

- name: Deploy via SSM
  run: |
    ENV_B64=$(cat env.b64)

    COMMAND_ID=$(aws ssm send-command \
      --instance-ids "${{ secrets.EC2_INSTANCE_ID }}" \
      --document-name "AWS-RunShellScript" \
      --parameters "commands=[
        \"echo '$ENV_B64' | base64 -d > /home/ssm-user/infra/.env\",
        \"sudo chown ssm-user:ssm-user /home/ssm-user/infra/.env\",
        \"sudo -u ssm-user -H bash /home/ssm-user/infra/scripts/deploy.sh\"
        ]" \
      ...)
```

`.env` 원본은 GitHub Secrets 의 `ENV_FILE` 에 들어 있습니다.

---

## 3. 문제점

### 3-1. 시크릿이 SSM 명령 이력에 남는다 (주요 사안)

`--parameters` 로 넘긴 명령어 문자열은 SSM 이 **명령 실행 기록으로 보존**합니다.
`aws ssm list-commands`, `aws ssm describe-instance-information` 계열 조회와
CloudTrail `SendCommand` 이벤트에서 확인할 수 있습니다.

**base64 는 인코딩이지 암호화가 아닙니다.** `base64 -d` 한 번이면 원문입니다.

영향 범위:

- 해당 AWS 계정에 SSM 읽기 권한이 있는 사람은 누구나 전체 `.env` 를 복원할 수 있음
- 기본 보존 기간(30일) 동안 축적되며, CloudTrail 을 S3 로 내보내고 있다면 그쪽에도 남음
- 시크릿을 교체(rotate)해도 **과거 이력의 옛 값은 그대로 남음**

### 3-2. 셸 인젝션 / 값 깨짐 위험

`printf "%s" "${{ secrets.ENV_FILE }}"` 는 시크릿 값을 셸 명령에 직접 문자열 치환합니다.
`ENV_FILE` 안에 `"`, `` ` ``, `$(` 가 들어가면 명령이 깨지거나 의도치 않게 실행될 수 있습니다.
현재 값에 특수문자가 없어 우연히 동작하는 상태이며,
비밀번호를 강한 값으로 바꾸는 순간 터질 수 있습니다.

### 3-3. `.env` 파일 권한이 느슨하다

```bash
sudo chown ssm-user:ssm-user /home/ssm-user/infra/.env
```

소유자만 바꾸고 **권한 비트는 건드리지 않습니다.**
root 의 기본 umask 로 생성되어 보통 `644` 가 되고, 인스턴스의 다른 계정에서 읽을 수 있습니다.

---

## 4. 개선안

### 권장: SSM Parameter Store (SecureString) 로 이전

```
GitHub Actions                          EC2
──────────────                          ───
send-command (시크릿 없음)  ─────────▶  deploy.sh
                                          └ aws ssm get-parameter \
                                              --name /gamehouse/prod/env \
                                              --with-decryption
                                            → umask 077 로 .env 작성
```

**변경 내용**

1. `.env` 전체를 SecureString 파라미터로 저장
   ```bash
   aws ssm put-parameter \
     --name /gamehouse/prod/env \
     --type SecureString \
     --key-id alias/gamehouse-secrets \
     --value file://.env \
     --overwrite
   ```

2. `deploy.sh` 앞부분에 `.env` 생성 단계 추가
   ```bash
   umask 077
   aws ssm get-parameter \
     --name /gamehouse/prod/env \
     --with-decryption \
     --query Parameter.Value \
     --output text > "${INFRA_DIR}/.env"
   ```

3. 워크플로에서 `Encode ENV_FILE` step 과 `.env` 관련 command 2줄 삭제
   → `send-command` 는 `deploy.sh` 실행 한 줄만 남음

4. GitHub Secrets 에서 `ENV_FILE` 제거

**필요한 권한 작업 (AWS 콘솔/IaC)**

| 대상 | 추가할 권한 |
|---|---|
| EC2 인스턴스 롤 | `ssm:GetParameter` on `/gamehouse/prod/*`, `kms:Decrypt` on 해당 CMK |
| GitHub OIDC 롤 | 변경 없음 (오히려 시크릿을 다루지 않게 되어 축소) |

**부수 효과**

- 시크릿 교체가 GitHub Secrets 편집 → `put-parameter` 로 바뀌어 감사 로그가 남음
- 파라미터 버전 관리가 되어 롤백 가능
- 워크플로 3개에 흩어져 있던 동일 시크릿이 한 곳으로 모임

### 대안

- **Secrets Manager** — 자동 로테이션이 필요해지면. 지금 규모에는 비용 대비 과함
- **최소 수정** — AWS 리소스를 못 건드릴 경우, 최소한 아래 두 가지만이라도
  ```yaml
  - name: Deploy via SSM
    env:
      ENV_FILE: ${{ secrets.ENV_FILE }}   # 문자열 보간 대신 환경변수로
    run: |
      ENV_B64=$(printf "%s" "$ENV_FILE" | base64 -w0)
  ```
  그리고 원격 명령에 `chmod 600 /home/ssm-user/infra/.env` 추가.
  **단, 3-1(명령 이력 잔존)은 이 방법으로 해결되지 않습니다.**

---

## 5. 조치 후 확인

```bash
# 명령 이력에 시크릿 흔적이 없는지
aws ssm list-commands --max-results 5 \
  --query 'Commands[].Parameters' --output json

# EC2 에서 파일 권한
ls -l /home/ssm-user/infra/.env      # -rw------- 이어야 함
```

기존 이력 정리와 **현재 사용 중인 시크릿 전량 교체**도 함께 검토가 필요합니다.
이미 노출된 값은 방식을 바꿔도 그대로 유효하기 때문입니다.

---

## 6. 참고: 함께 논의된 다른 항목

이번 브랜치(`fix/cd-pipeline`)에서 이미 수정했거나, 별도 과제로 남긴 것들입니다.

| 항목 | 상태 |
|---|---|
| SSM 폴링 루프가 타임아웃에도 초록불 | ✅ 수정 |
| backend `cancel-in-progress` 가 배포 중 job 취소 | ✅ 수정 |
| observability 스택이 CD 를 타지 않음 | ✅ 수정 |
| 시크릿 전달 방식 | 📄 이 문서 |
| 배포 이미지가 `-develop` 가변 태그 → 커밋 고정 안 됨 | ⏳ 미해결 |
| 롤백 절차 없음 | ⏳ 미해결 |
| 무중단 배포 아님 (`up -d` 순단) | ⏳ 미해결 |
| `cadvisor:latest` 태그 미고정 | ⏳ 미해결 |
| backend gitleaks 가 `:latest` (frontend/infra 는 고정) | ⏳ 미해결 |
